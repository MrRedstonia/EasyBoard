// App routing on Windows: lists the processes with audio sessions and captures one process (and
// its child processes) with WASAPI process loopback. The app keeps playing normally.
// Process loopback needs Windows 10 version 2004 (build 19041) or newer.
// C API used by src/audio/apps_native.rs.
#ifdef _WIN32
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <audioclientactivationparams.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "mmdevapi.lib")
#pragma comment(lib, "version.lib")

using Microsoft::WRL::ComPtr;

typedef void (*eb_app_cb)(void *ctx, uint64_t id, int32_t pid, int32_t active, const char *key, const char *name, const char *icon);
typedef void (*eb_audio_cb)(void *ctx, const float *data, uint32_t frames, uint32_t rate);

namespace {

struct ComInit {
    HRESULT hr;
    ComInit() : hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComInit() { if (SUCCEEDED(hr)) CoUninitialize(); }
};

std::string utf8(const std::wstring &w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring exe_path(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return {};
    wchar_t buf[1024];
    DWORD n = 1024;
    std::wstring r;
    if (QueryFullProcessImageNameW(h, 0, buf, &n)) r.assign(buf, n);
    CloseHandle(h);
    return r;
}

// "FileDescription" from the exe's version info ("Google Chrome", "Spotify"), or "" if none.
std::wstring file_description(const std::wstring &path) {
    static std::mutex m;
    static std::map<std::wstring, std::wstring> cache;
    std::lock_guard<std::mutex> lock(m);
    auto it = cache.find(path);
    if (it != cache.end()) return it->second;
    std::wstring result;
    DWORD dummy = 0;
    DWORD size = GetFileVersionInfoSizeW(path.c_str(), &dummy);
    if (size) {
        std::vector<BYTE> data(size);
        struct LangCp { WORD lang, cp; } *tr = nullptr;
        UINT len = 0;
        if (GetFileVersionInfoW(path.c_str(), 0, size, data.data()) &&
            VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", (LPVOID *)&tr, &len) && len >= sizeof(LangCp)) {
            wchar_t q[80];
            swprintf(q, 80, L"\\StringFileInfo\\%04x%04x\\FileDescription", tr[0].lang, tr[0].cp);
            wchar_t *val = nullptr;
            UINT vlen = 0;
            if (VerQueryValueW(data.data(), q, (LPVOID *)&val, &vlen) && val && vlen > 1) result = val;
        }
    }
    while (!result.empty() && iswspace(result.back())) result.pop_back();
    cache[path] = result;
    return result;
}

std::wstring file_name(const std::wstring &path) {
    size_t s = path.find_last_of(L"\\/");
    return s == std::wstring::npos ? path : path.substr(s + 1);
}

class Handler : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                    Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
public:
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ~Handler() { CloseHandle(done); }
    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation *) override {
        SetEvent(done);
        return S_OK;
    }
};

struct Tap {
    std::atomic<bool> stop{false};
    std::atomic<bool> alive{true};
    std::thread thread;
};

const UINT32 RATE = 48000;

// Opens the loopback client for `pid`; returns "" or an error message.
std::string open_client(DWORD pid, ComPtr<IAudioClient> &client, bool &is_float) {
    AUDIOCLIENT_ACTIVATION_PARAMS ap = {};
    ap.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    ap.ProcessLoopbackParams.TargetProcessId = pid;
    ap.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(ap);
    pv.blob.pBlobData = reinterpret_cast<BYTE *>(&ap);

    auto handler = Microsoft::WRL::Make<Handler>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
                                             handler.Get(), &op);
    if (FAILED(hr)) return "process loopback is not available (Windows 10 2004 or newer is needed)";
    if (WaitForSingleObject(handler->done, 5000) != WAIT_OBJECT_0) return "process loopback did not start";
    HRESULT ahr = E_FAIL;
    ComPtr<IUnknown> unk;
    if (FAILED(op->GetActivateResult(&ahr, &unk)) || FAILED(ahr) || !unk) return "process loopback was refused";
    if (FAILED(unk.As(&client))) return "process loopback gave no audio client";

    // Float first; 16-bit PCM as a fallback. AUTOCONVERTPCM lets Windows resample to 48 kHz.
    for (int attempt = 0; attempt < 2; attempt++) {
        WAVEFORMATEX f = {};
        is_float = attempt == 0;
        f.wFormatTag = is_float ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
        f.nChannels = 2;
        f.nSamplesPerSec = RATE;
        f.wBitsPerSample = is_float ? 32 : 16;
        f.nBlockAlign = f.nChannels * f.wBitsPerSample / 8;
        f.nAvgBytesPerSec = f.nSamplesPerSec * f.nBlockAlign;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                200000 /* 20 ms */, 0, &f, nullptr);
        if (SUCCEEDED(hr)) return {};
    }
    char m[64];
    snprintf(m, sizeof m, "could not start the capture (0x%08lx)", (unsigned long)hr);
    return m;
}

void run(Tap *t, DWORD pid, eb_audio_cb cb, void *ctx, std::shared_ptr<std::promise<std::string>> ready) {
    ComInit com;
    ComPtr<IAudioClient> client;
    bool is_float = true;
    std::string err = open_client(pid, client, is_float);
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ComPtr<IAudioCaptureClient> cap;
    if (err.empty() && (FAILED(client->SetEventHandle(ev)) || FAILED(client->GetService(IID_PPV_ARGS(&cap))) ||
                        FAILED(client->Start())))
        err = "could not start the capture";
    ready->set_value(err);
    if (!err.empty()) {
        CloseHandle(ev);
        t->alive = false;
        return;
    }
    std::vector<float> buf;
    while (!t->stop) {
        if (WaitForSingleObject(ev, 200) != WAIT_OBJECT_0) continue;
        UINT32 packet = 0;
        bool failed = false;
        while (!t->stop) {
            if (FAILED(cap->GetNextPacketSize(&packet))) { failed = true; break; }
            if (packet == 0) break;
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) { failed = true; break; }
            buf.assign((size_t)frames * 2, 0.0f);
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data) {
                if (is_float) {
                    memcpy(buf.data(), data, buf.size() * sizeof(float));
                } else {
                    const int16_t *s = reinterpret_cast<const int16_t *>(data);
                    for (size_t i = 0; i < buf.size(); i++) buf[i] = s[i] / 32768.0f;
                }
            }
            cap->ReleaseBuffer(frames);
            if (frames) cb(ctx, buf.data(), frames, RATE);
        }
        if (failed) break;
    }
    client->Stop();
    CloseHandle(ev);
    t->alive = false;
}

} // namespace

extern "C" int eb_apps_supported(void) {
    typedef LONG(WINAPI * RtlGetVersionFn)(OSVERSIONINFOW *);
    auto fn = (RtlGetVersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    OSVERSIONINFOW v = {};
    v.dwOSVersionInfoSize = sizeof v;
    if (!fn || fn(&v) != 0) return 0;
    return v.dwMajorVersion > 10 || (v.dwMajorVersion == 10 && v.dwBuildNumber >= 19041);
}

extern "C" void eb_apps_list(eb_app_cb cb, void *ctx) {
    ComInit com;
    ComPtr<IMMDeviceEnumerator> en;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&en)))) return;
    ComPtr<IMMDeviceCollection> devs;
    if (FAILED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devs))) return;
    UINT count = 0;
    devs->GetCount(&count);
    std::map<DWORD, bool> pids; // pid -> playing right now
    for (UINT i = 0; i < count; i++) {
        ComPtr<IMMDevice> dev;
        ComPtr<IAudioSessionManager2> mgr;
        ComPtr<IAudioSessionEnumerator> sessions;
        if (FAILED(devs->Item(i, &dev)) ||
            FAILED(dev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, (void **)mgr.GetAddressOf())) ||
            FAILED(mgr->GetSessionEnumerator(&sessions)))
            continue;
        int n = 0;
        sessions->GetCount(&n);
        for (int j = 0; j < n; j++) {
            ComPtr<IAudioSessionControl> sc;
            ComPtr<IAudioSessionControl2> sc2;
            if (FAILED(sessions->GetSession(j, &sc)) || FAILED(sc.As(&sc2))) continue;
            if (sc2->IsSystemSoundsSession() == S_OK) continue;
            DWORD pid = 0;
            AudioSessionState st = AudioSessionStateInactive;
            if (FAILED(sc2->GetProcessId(&pid)) || pid == 0 || FAILED(sc->GetState(&st))) continue;
            if (st == AudioSessionStateExpired) continue;
            pids[pid] = pids[pid] || st == AudioSessionStateActive;
        }
    }
    for (auto &p : pids) {
        std::wstring path = exe_path(p.first);
        if (path.empty()) continue;
        std::wstring exe = file_name(path);
        std::wstring name = file_description(path);
        if (name.empty()) {
            name = exe;
            size_t dot = name.find_last_of(L'.');
            if (dot != std::wstring::npos) name = name.substr(0, dot);
        }
        std::wstring key = exe;
        for (auto &c : key) c = towlower(c);
        cb(ctx, p.first, (int32_t)p.first, p.second ? 1 : 0, utf8(key).c_str(), utf8(name).c_str(), utf8(path).c_str());
    }
}

extern "C" void *eb_tap_start(uint64_t id, eb_audio_cb cb, void *ctx, char *err, int errcap) {
    auto *t = new Tap;
    auto ready = std::make_shared<std::promise<std::string>>();
    auto result = ready->get_future();
    t->thread = std::thread(run, t, (DWORD)id, cb, ctx, ready);
    std::string e = result.get();
    if (!e.empty()) {
        t->thread.join();
        delete t;
        if (err && errcap > 0) snprintf(err, errcap, "%s", e.c_str());
        return nullptr;
    }
    return t;
}

extern "C" int eb_tap_alive(void *h) {
    return h && static_cast<Tap *>(h)->alive ? 1 : 0;
}

extern "C" void eb_tap_stop(void *h) {
    if (!h) return;
    auto *t = static_cast<Tap *>(h);
    t->stop = true;
    if (t->thread.joinable()) t->thread.join();
    delete t;
}
#endif
