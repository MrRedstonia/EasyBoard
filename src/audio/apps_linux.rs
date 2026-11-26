//! App routing on Linux: playback streams come from `pactl`, each one is recorded with
//! `parec --monitor-stream=<index>` (which leaves the stream where it is, so you still hear it).

use super::{AudioApp, RateQueue, Target};
use parking_lot::Mutex;
use std::{
    collections::HashMap,
    io::Read,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{atomic::{AtomicBool, Ordering}, Arc},
    time::{Duration, Instant},
};

const RATE: u32 = 48_000;

pub fn supported() -> bool {
    true
}

pub fn targets() -> Vec<Target> {
    let Ok(out) = Command::new("pactl").args(["-f", "json", "list", "sink-inputs"]).output() else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&out.stdout) else { return Vec::new() };
    let own = std::process::id().to_string();
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let p = &e["properties"];
            let prop = |k: &str| p[k].as_str().unwrap_or("").to_string();
            let pid = prop("application.process.id");
            if pid == own || prop("application.name") == "EasyBoard" || prop("media.role") == "event" {
                return None;
            }
            let app = identify(p);
            if app.name.to_lowercase().starts_with("easyboard") {
                return None;
            }
            Some(Target { id: e["index"].as_u64()?, app, active: !e["corked"].as_bool().unwrap_or(false) })
        })
        .collect()
}

// ------------------------------------------------------ app identity ----

/// Process names that say nothing about which app it is.
const GENERIC: &[&str] = &[
    "electron", "python", "python3", "java", "node", "sh", "bash", "wine", "wine64", "wine-preloader",
    "wine64-preloader", "pipewire", "pw-play", "paplay", "aplay",
];

static IDENTITIES: Mutex<Option<HashMap<String, AudioApp>>> = Mutex::new(None);

fn identify(p: &serde_json::Value) -> AudioApp {
    let prop = |k: &str| p[k].as_str().unwrap_or("").to_string();
    let (pid, binary, name) = (prop("application.process.id"), prop("application.process.binary"), prop("application.name"));
    let cache_key = format!("{pid}\u{1}{binary}\u{1}{name}");
    if let Some(a) = IDENTITIES.lock().get_or_insert_with(HashMap::new).get(&cache_key) {
        return a.clone();
    }
    let app = resolve(&pid, &binary, &name, &prop("application.icon_name"), &prop("pipewire.access.portal.app_id"));
    IDENTITIES.lock().get_or_insert_with(HashMap::new).insert(cache_key, app.clone());
    app
}

fn resolve(pid: &str, binary: &str, app_name: &str, icon_name: &str, flatpak_id: &str) -> AudioApp {
    let is_generic = |s: &str| GENERIC.contains(&s.to_lowercase().as_str());
    let electron = binary.eq_ignore_ascii_case("electron") || exe_of(pid).map(|e| e.contains("electron")).unwrap_or(false);
    // Electron apps call their audio stream "Chromium": look at the command lines for the real app.
    let (asar_dir, data_dir) = if electron || is_generic(binary) { electron_hints(pid) } else { (None, None) };
    let app_name = if electron && app_name.eq_ignore_ascii_case("chromium") { "" } else { app_name };

    let mut tokens: Vec<String> = Vec::new();
    for t in [flatpak_id, icon_name, asar_dir.as_deref().unwrap_or(""), binary, app_name, data_dir.as_deref().unwrap_or("")] {
        if !t.is_empty() && !is_generic(t) && !tokens.iter().any(|x| x.eq_ignore_ascii_case(t)) {
            tokens.push(t.to_string());
        }
    }

    if let Some(d) = find_desktop(&tokens) {
        let icon = if d.icon.is_empty() {
            String::new()
        } else if d.icon.starts_with('/') {
            format!("file:{}", d.icon)
        } else {
            format!("theme:{}", d.icon)
        };
        return AudioApp { key: format!("desktop:{}", d.id), name: d.name, icon };
    }

    let name = [app_name, data_dir.as_deref().unwrap_or(""), binary]
        .into_iter()
        .find(|s| !s.is_empty() && !is_generic(s))
        .or(if binary.is_empty() { None } else { Some(binary) })
        .unwrap_or("Unknown app")
        .to_string();
    let icon = if !icon_name.is_empty() {
        format!("theme:{icon_name}")
    } else if !binary.is_empty() && !is_generic(binary) {
        format!("theme:{}", binary.to_lowercase())
    } else {
        String::new()
    };
    AudioApp { key: format!("name:{}", name.to_lowercase()), name, icon }
}

fn exe_of(pid: &str) -> Option<String> {
    if pid.is_empty() {
        return None;
    }
    std::fs::read_link(format!("/proc/{pid}/exe")).ok().map(|p| p.to_string_lossy().into_owned())
}

fn cmdline(pid: &str) -> Vec<String> {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|b| b.split(|c| *c == 0).filter(|s| !s.is_empty()).map(|s| String::from_utf8_lossy(s).into_owned()).collect())
        .unwrap_or_default()
}

fn parent_pid(pid: &str) -> Option<String> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // "pid (comm) state ppid ..." – comm may contain spaces, so start after the last ')'
    stat.rsplit_once(')')?.1.split_whitespace().nth(1).map(str::to_string)
}

/// (folder name holding the app's .asar, basename of --user-data-dir) from the process and its
/// parents (the audio stream belongs to a helper process of the main one).
fn electron_hints(pid: &str) -> (Option<String>, Option<String>) {
    let (mut asar, mut data) = (None, None);
    let mut cur = pid.to_string();
    for _ in 0..4 {
        if cur.is_empty() || cur == "0" || cur == "1" {
            break;
        }
        for arg in cmdline(&cur) {
            if asar.is_none() && arg.ends_with(".asar") {
                let p = Path::new(&arg);
                let dir = p.parent().and_then(|d| d.file_name()).map(|s| s.to_string_lossy().into_owned());
                // /usr/lib/<app>/app.asar or /opt/<App>/resources/app.asar
                asar = match dir.as_deref() {
                    Some("resources") => p.parent().and_then(|d| d.parent()).and_then(|d| d.file_name()).map(|s| s.to_string_lossy().into_owned()),
                    _ => dir,
                };
            }
            if data.is_none() {
                if let Some(d) = arg.strip_prefix("--user-data-dir=") {
                    data = Path::new(d).file_name().map(|s| s.to_string_lossy().into_owned());
                }
            }
        }
        if asar.is_some() && data.is_some() {
            break;
        }
        cur = parent_pid(&cur).unwrap_or_default();
    }
    (asar, data)
}

// ---------------------------------------------------- .desktop files ----

#[derive(Clone)]
struct Desktop {
    /// File name without ".desktop".
    id: String,
    name: String,
    icon: String,
    exec: String,
    wm_class: String,
}

static DESKTOPS: Mutex<Option<(Instant, Vec<Desktop>)>> = Mutex::new(None);

fn desktop_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let data_home = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local/share"));
    let mut dirs = vec![data_home.join("applications"), data_home.join("flatpak/exports/share/applications")];
    let data_dirs = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    dirs.extend(data_dirs.split(':').filter(|d| !d.is_empty()).map(|d| Path::new(d).join("applications")));
    dirs.push("/var/lib/flatpak/exports/share/applications".into());
    dirs.push("/var/lib/snapd/desktop/applications".into());
    dirs
}

fn load_desktops() -> Vec<Desktop> {
    let mut out: Vec<Desktop> = Vec::new();
    for dir in desktop_dirs() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let path = e.path();
            if path.extension().and_then(|x| x.to_str()) != Some("desktop") {
                continue;
            }
            let id = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if out.iter().any(|d| d.id == id) {
                continue; // earlier directories win, as in the XDG spec
            }
            let Ok(text) = std::fs::read_to_string(&path) else { continue };
            let mut d = Desktop { id, name: String::new(), icon: String::new(), exec: String::new(), wm_class: String::new() };
            let mut in_main = false;
            for line in text.lines() {
                let line = line.trim();
                if line.starts_with('[') {
                    in_main = line == "[Desktop Entry]";
                    continue;
                }
                if !in_main {
                    continue;
                }
                if let Some((k, v)) = line.split_once('=') {
                    match k.trim() {
                        "Name" => d.name = v.trim().to_string(),
                        "Icon" => d.icon = v.trim().to_string(),
                        "Exec" => d.exec = exec_name(v),
                        "StartupWMClass" => d.wm_class = v.trim().to_string(),
                        _ => {}
                    }
                }
            }
            if !d.name.is_empty() {
                out.push(d);
            }
        }
    }
    out
}

/// The program an Exec= line starts, without its folder ("env FOO=1 /opt/x/app %U" -> "app").
fn exec_name(exec: &str) -> String {
    let mut words = exec.split_whitespace().map(|w| w.trim_matches('"'));
    let mut w = words.next().unwrap_or("");
    if Path::new(w).file_name().map(|n| n == "env").unwrap_or(false) {
        w = words.find(|x| !x.contains('=')).unwrap_or("");
    }
    Path::new(w).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn find_desktop(tokens: &[String]) -> Option<Desktop> {
    if tokens.is_empty() {
        return None;
    }
    let mut cache = DESKTOPS.lock();
    if cache.as_ref().map(|(t, _)| t.elapsed() > Duration::from_secs(60)).unwrap_or(true) {
        *cache = Some((Instant::now(), load_desktops()));
    }
    let list = &cache.as_ref()?.1;
    let eq = |a: &str, b: &str| !a.is_empty() && a.eq_ignore_ascii_case(b);
    // tokens are ordered from most to least specific; for each, try the strongest kinds of match
    for t in tokens {
        let t = t.as_str();
        let found = list.iter().find(|d| eq(&d.id, t) || d.id.to_lowercase().ends_with(&format!(".{}", t.to_lowercase())))
            .or_else(|| list.iter().find(|d| eq(&d.exec, t)))
            .or_else(|| list.iter().find(|d| eq(&d.wm_class, t)))
            .or_else(|| list.iter().find(|d| eq(&d.icon, t)))
            .or_else(|| list.iter().find(|d| eq(&d.name, t)));
        if let Some(d) = found {
            return Some(d.clone());
        }
    }
    None
}

// --------------------------------------------------------- capture ----

/// A running `parec --monitor-stream` for one sink input.
pub struct Capture {
    child: Child,
    alive: Arc<AtomicBool>,
}

impl Capture {
    pub fn start(index: u64, queue: Arc<RateQueue>) -> Result<Self, String> {
        let mut child = Command::new("parec")
            .args([
                &format!("--monitor-stream={index}"),
                "--raw",
                "--format=float32le",
                &format!("--rate={RATE}"),
                "--channels=2",
                "--latency-msec=20",
                "--client-name=EasyBoard",
                "--stream-name=EasyBoard app routing",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| format!("could not run parec ({e}). Install pulseaudio-utils / libpulse."))?;
        let mut out = child.stdout.take().ok_or("no parec output")?;
        let alive = Arc::new(AtomicBool::new(true));
        let a = alive.clone();
        std::thread::Builder::new()
            .name("easyboard-appcap".into())
            .spawn(move || {
                let mut bytes = vec![0u8; 960 * 2 * 4]; // 10 ms
                let mut samples = Vec::with_capacity(960 * 2);
                let mut carry = 0usize;
                loop {
                    match out.read(&mut bytes[carry..]) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let have = carry + n;
                            let whole = have / 8 * 8; // complete stereo frames only
                            samples.clear();
                            samples.extend(bytes[..whole].as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])));
                            queue.push(&samples, RATE);
                            bytes.copy_within(whole..have, 0);
                            carry = have - whole;
                        }
                    }
                }
                a.store(false, Ordering::SeqCst);
            })
            .map_err(|e| e.to_string())?;
        Ok(Capture { child, alive })
    }

    pub fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
