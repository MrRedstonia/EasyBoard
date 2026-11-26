// App routing on macOS: lists the processes known to Core Audio and captures one of them with a
// process tap (macOS 14.2 or newer). The tap is "unmuted", so the app keeps playing normally.
// The first capture asks for permission (NSAudioCaptureUsageDescription in Info.plist).
// C API used by src/audio/apps_native.rs. Built with ARC (see build.rs).
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <dlfcn.h>
#include <vector>

typedef void (*eb_app_cb)(void *ctx, uint64_t id, int32_t pid, int32_t active, const char *key, const char *name, const char *icon);
typedef void (*eb_audio_cb)(void *ctx, const float *data, uint32_t frames, uint32_t rate);

#if __has_include(<CoreAudio/AudioHardwareTapping.h>)
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

// Everything new is looked up at run time so the app still starts on older macOS versions.
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

typedef OSStatus (*CreateTapFn)(CATapDescription *, AudioObjectID *);
typedef OSStatus (*DestroyTapFn)(AudioObjectID);
typedef pid_t (*ResponsibleFn)(pid_t);

static CreateTapFn create_tap() { return (CreateTapFn)dlsym(RTLD_DEFAULT, "AudioHardwareCreateProcessTap"); }
static DestroyTapFn destroy_tap() { return (DestroyTapFn)dlsym(RTLD_DEFAULT, "AudioHardwareDestroyProcessTap"); }

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel) {
    return {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

template <typename T> static bool get_prop(AudioObjectID obj, AudioObjectPropertySelector sel, T &out) {
    AudioObjectPropertyAddress a = addr(sel);
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, &out) == noErr;
}

extern "C" int eb_apps_supported(void) {
    NSOperatingSystemVersion v = {14, 2, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:v] && create_tap() &&
           NSClassFromString(@"CATapDescription") != nil;
}

extern "C" void eb_apps_list(eb_app_cb cb, void *ctx) {
    if (!eb_apps_supported()) return;
    @autoreleasepool {
        AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyProcessObjectList);
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr || size == 0) return;
        std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) return;
        ids.resize(size / sizeof(AudioObjectID));
        // WebKit and other helper processes play audio for an app: show that app instead.
        auto responsible = (ResponsibleFn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");

        for (AudioObjectID obj : ids) {
            pid_t pid = -1;
            UInt32 running = 0;
            if (!get_prop(obj, kAudioProcessPropertyPID, pid) || pid <= 0) continue;
            get_prop(obj, kAudioProcessPropertyIsRunningOutput, running);

            pid_t owner = pid;
            if (responsible) {
                pid_t r = responsible(pid);
                if (r > 0) owner = r;
            }
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:owner];
            if (!app) app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            NSString *key = app.bundleIdentifier;
            NSString *name = app.localizedName;
            NSString *path = app.bundleURL.path;
            // a helper bundle inside another app (".../Foo.app/Contents/Frameworks/Foo Helper.app")
            if (path) {
                NSRange r = [path rangeOfString:@".app/"];
                if (r.location != NSNotFound) {
                    NSString *outer = [path substringToIndex:r.location + 4];
                    NSBundle *b = [NSBundle bundleWithPath:outer];
                    if (b) {
                        path = outer;
                        if (b.bundleIdentifier) key = b.bundleIdentifier;
                        NSString *n = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                                          ?: [b objectForInfoDictionaryKey:@"CFBundleName"];
                        if (n) name = n;
                    }
                }
            }
            if (!key.length) {
                CFStringRef bid = nullptr;
                if (get_prop(obj, kAudioProcessPropertyBundleID, bid) && bid) key = CFBridgingRelease(bid);
            }
            if (!key.length) continue;
            if (!name.length) name = key;
            cb(ctx, obj, pid, running ? 1 : 0, key.UTF8String, name.UTF8String, path ? path.UTF8String : "");
        }
    }
}

struct Tap {
    AudioObjectID tap = kAudioObjectUnknown;
    AudioObjectID agg = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    bool started = false;
    eb_audio_cb cb = nullptr;
    void *ctx = nullptr;
    uint32_t rate = 48000;
    std::vector<float> scratch;

    void deliver(const AudioBufferList *in) {
        if (!in || in->mNumberBuffers == 0) return;
        const AudioBuffer &b0 = in->mBuffers[0];
        if (!b0.mData) return;
        UInt32 frames;
        if (in->mNumberBuffers == 1 && b0.mNumberChannels >= 2) {
            // interleaved
            UInt32 ch = b0.mNumberChannels;
            frames = b0.mDataByteSize / (sizeof(float) * ch);
            if (ch == 2) {
                cb(ctx, static_cast<const float *>(b0.mData), frames, rate);
                return;
            }
            scratch.resize(frames * 2);
            const float *s = static_cast<const float *>(b0.mData);
            for (UInt32 i = 0; i < frames; i++) { scratch[i * 2] = s[i * ch]; scratch[i * 2 + 1] = s[i * ch + 1]; }
        } else {
            // one buffer per channel (or mono)
            frames = b0.mDataByteSize / sizeof(float);
            const float *l = static_cast<const float *>(b0.mData);
            const float *r = in->mNumberBuffers > 1 && in->mBuffers[1].mData ? static_cast<const float *>(in->mBuffers[1].mData) : l;
            scratch.resize(frames * 2);
            for (UInt32 i = 0; i < frames; i++) { scratch[i * 2] = l[i]; scratch[i * 2 + 1] = r[i]; }
        }
        cb(ctx, scratch.data(), frames, rate);
    }

    void close() {
        if (agg != kAudioObjectUnknown) {
            if (proc) {
                if (started) AudioDeviceStop(agg, proc);
                AudioDeviceDestroyIOProcID(agg, proc);
            }
            AudioHardwareDestroyAggregateDevice(agg);
        }
        if (tap != kAudioObjectUnknown) {
            if (auto d = destroy_tap()) d(tap);
        }
        agg = tap = kAudioObjectUnknown;
        proc = nullptr;
    }
};

static void *fail(Tap *t, char *err, int errcap, const char *what, OSStatus s) {
    if (err && errcap > 0) snprintf(err, errcap, "%s (%d)", what, (int)s);
    t->close();
    delete t;
    return nullptr;
}

extern "C" void *eb_tap_start(uint64_t id, eb_audio_cb cb, void *ctx, char *err, int errcap) {
    auto *t = new Tap;
    t->cb = cb;
    t->ctx = ctx;
    if (!eb_apps_supported()) return fail(t, err, errcap, "app routing needs macOS 14.2 or newer", 0);
    @autoreleasepool {
        Class cls = NSClassFromString(@"CATapDescription");
        CATapDescription *desc = [[cls alloc] initStereoMixdownOfProcesses:@[ @((AudioObjectID)id) ]];
        NSUUID *uuid = [NSUUID UUID];
        desc.name = @"EasyBoard app routing";
        desc.UUID = uuid;
        desc.privateTap = YES;
        desc.muteBehavior = CATapUnmuted;
        OSStatus s = create_tap()(desc, &t->tap);
        if (s != noErr) return fail(t, err, errcap, "could not create the audio tap", s);

        // the aggregate device is clocked by the current output device
        AudioObjectID out = kAudioObjectUnknown;
        CFStringRef outUID = nullptr;
        if (!get_prop(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, out) ||
            !get_prop(out, kAudioDevicePropertyDeviceUID, outUID) || !outUID)
            return fail(t, err, errcap, "no output device", 0);
        NSString *outputUID = CFBridgingRelease(outUID);

        NSDictionary *d = @{
            // (EasyBoard's own device lists hide this name: src/audio/cpal_out.rs is_routing_device)
            @kAudioAggregateDeviceNameKey : @"EasyBoard App Routing",
            @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
            @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
            @kAudioAggregateDeviceIsPrivateKey : @YES,
            @kAudioAggregateDeviceIsStackedKey : @NO,
            @kAudioAggregateDeviceTapAutoStartKey : @YES,
            @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : outputUID} ],
            @kAudioAggregateDeviceTapListKey : @[ @{
                @kAudioSubTapDriftCompensationKey : @YES,
                @kAudioSubTapUIDKey : uuid.UUIDString,
            } ],
        };
        s = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)d, &t->agg);
        if (s != noErr) return fail(t, err, errcap, "could not create the capture device", s);

        Float64 rate = 0;
        if (get_prop(t->agg, kAudioDevicePropertyNominalSampleRate, rate) && rate > 0) t->rate = (uint32_t)rate;

        Tap *tp = t;
        s = AudioDeviceCreateIOProcIDWithBlock(&t->proc, t->agg, nullptr,
                                               ^(const AudioTimeStamp *, const AudioBufferList *in, const AudioTimeStamp *,
                                                 AudioBufferList *, const AudioTimeStamp *) { tp->deliver(in); });
        if (s != noErr) return fail(t, err, errcap, "could not start the capture", s);
        s = AudioDeviceStart(t->agg, t->proc);
        if (s != noErr) return fail(t, err, errcap, "could not start the capture (is the permission granted?)", s);
        t->started = true;
    }
    return t;
}

extern "C" int eb_tap_alive(void *h) { return h ? 1 : 0; }

extern "C" void eb_tap_stop(void *h) {
    if (!h) return;
    auto *t = static_cast<Tap *>(h);
    t->close();
    delete t;
}

#else // SDK older than macOS 14.2: app routing is not available

extern "C" int eb_apps_supported(void) { return 0; }
extern "C" void eb_apps_list(eb_app_cb, void *) {}
extern "C" void *eb_tap_start(uint64_t, eb_audio_cb, void *, char *err, int errcap) {
    if (err && errcap > 0) snprintf(err, errcap, "EasyBoard was built without app routing support");
    return nullptr;
}
extern "C" int eb_tap_alive(void *) { return 0; }
extern "C" void eb_tap_stop(void *) {}

#endif
