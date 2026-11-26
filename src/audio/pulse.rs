//! Linux backend: libpulse (simple API) + `pactl` for the virtual inputs.

use super::InputDevice;
use crate::{
    config::Config,
    mixer::{Mixer, OUT_LOCAL, OUT_VIRTUAL},
};
use libpulse_binding::{def::BufferAttr, sample::{Format, Spec}, stream::Direction};
use libpulse_simple_binding::Simple;
use parking_lot::Mutex;
use std::{
    process::Command,
    sync::{atomic::{AtomicBool, Ordering}, Arc},
    thread::{self, JoinHandle},
};

const RATE: u32 = 48_000;
const CHUNK_FRAMES: usize = 960; // 20 ms

// Topology: no helper sinks and no change to the default input.
//
//   soundboard --> FIFO --> [module-pipe-source "EasyBoard Sink"]   (soundboard only)
//   real mic  ----+                                                  (the mic's own slider)
//   "EasyBoard Sink" --+--> in-app mix --> FIFO --> [pipe-source "EasyBoard Mic"]
//
// "EasyBoard Sink" and "EasyBoard Mic" are plain input devices; the only playback stream
// is the app's own "EasyBoard" stream (what you hear). Apps choose "EasyBoard Mic" (or
// "EasyBoard Sink") as their microphone; the system default input is never touched.
const SOUNDBOARD_SOURCE: &str = "EasyBoard_Sink";

static MODULES: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn pactl(args: &[&str]) -> Result<String, String> {
    let out = Command::new("pactl")
        .args(args)
        .output()
        .map_err(|e| format!("could not run pactl ({e}). Install pulseaudio-utils / pipewire-pulse."))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

pub fn list_inputs() -> Vec<InputDevice> {
    let Ok(json) = pactl(&["--format=json", "list", "sources"]) else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) else {
        return Vec::new();
    };
    v.as_array()
        .into_iter()
        .flatten()
        .filter(|s| s["monitor_of_sink"].is_null())
        .filter_map(|s| {
            let name = s["name"].as_str()?.to_string();
            if name.starts_with("EasyBoard") {
                return None;
            }
            let label = s["description"].as_str().unwrap_or(&name).to_string();
            Some(InputDevice { id: name, label })
        })
        .collect()
}

pub fn list_virtual_candidates() -> Vec<String> {
    Vec::new()
}

fn fifo_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    dir.join(format!("easyboard-{name}.fifo"))
}

/// Remove modules left behind by a previous (crashed) run.
fn cleanup_stale() {
    if let Ok(list) = pactl(&["list", "short", "modules"]) {
        for line in list.lines() {
            if line.contains("EasyBoard") || line.contains("easyboard-") {
                if let Some(id) = line.split_whitespace().next() {
                    let _ = pactl(&["unload-module", id]);
                }
            }
        }
    }
}

fn load_pipe_source(name: &str, description: &str) -> Result<(), String> {
    let path = fifo_path(name);
    let _ = std::fs::remove_file(&path);
    let id = pactl(&[
        "load-module", "module-pipe-source",
        &format!("file={}", path.display()),
        &format!("source_name=EasyBoard_{name}"),
        "format=float32le", "rate=48000", "channels=2",
        &format!("source_properties=\"device.description='{description}'\""),
    ])?;
    MODULES.lock().push(id);
    Ok(())
}

pub fn prepare_virtual(cfg: &Config) -> Result<(), String> {
    shutdown_virtual();
    cleanup_stale();
    load_pipe_source("Sink", "EasyBoard Sink")?;
    if mic_feed_needed(cfg) {
        load_pipe_source("Mic", "EasyBoard Mic")?;
    }
    Ok(())
}

/// "EasyBoard Mic" exists when a microphone is mixed in or apps are routed into it.
pub fn mic_feed_needed(cfg: &Config) -> bool {
    (cfg.mix_mic && !cfg.input_device.is_empty()) || cfg.routes_active()
}

pub fn set_mic_volume(v: f32) {
    let pct = (v.clamp(0.0, 1.5) * 100.0).round() as u32;
    let _ = pactl(&["set-source-volume", "EasyBoard_Mic", &format!("{pct}%")]);
}

/// Real PulseAudio mute: 0 = EasyBoard's own playback stream (what you hear), 1 = EasyBoard Sink,
/// 2 = EasyBoard Mic. Returns false when it could not be done (the caller then lowers the volume instead).
pub fn set_mute(which: usize, on: bool) -> bool {
    let flag = if on { "1" } else { "0" };
    match which {
        0 => {
            let ids = own_sink_inputs();
            if ids.is_empty() {
                return false;
            }
            ids.iter().all(|(i, _)| pactl(&["set-sink-input-mute", i.as_str(), flag]).is_ok())
        }
        1 => pactl(&["set-source-mute", "EasyBoard_Sink", flag]).is_ok(),
        _ => pactl(&["set-source-mute", "EasyBoard_Mic", flag]).is_ok(),
    }
}

/// Current system mute state [personal, sink, mic]; None when pactl is unavailable.
pub fn get_mutes() -> Option<[bool; 3]> {
    let src = |name: &str| -> bool {
        pactl(&["get-source-mute", name]).map(|o| o.to_ascii_lowercase().contains("yes")).unwrap_or(false)
    };
    let own = own_sink_inputs();
    Some([!own.is_empty() && own.iter().all(|(_, m)| *m), src("EasyBoard_Sink"), src("EasyBoard_Mic")])
}

/// (index, muted) of the playback streams that belong to this process.
fn own_sink_inputs() -> Vec<(String, bool)> {
    let Ok(out) = pactl(&["-f", "json", "list", "sink-inputs"]) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&out) else { return Vec::new() };
    let pid = std::process::id().to_string();
    v.as_array()
        .map(|a| {
            a.iter()
                .filter(|e| e["properties"]["application.process.id"].as_str() == Some(pid.as_str()))
                .filter_map(|e| Some((e["index"].as_u64()?.to_string(), e["mute"].as_bool().unwrap_or(false))))
                .collect()
        })
        .unwrap_or_default()
}

pub fn shutdown_virtual() {
    for id in MODULES.lock().drain(..).rev() {
        let _ = pactl(&["unload-module", &id]);
    }
    let _ = std::fs::remove_file(fifo_path("Sink"));
    let _ = std::fs::remove_file(fifo_path("Mic"));
}

pub fn start_outputs(mixer: Arc<Mixer>, cfg: &Config, stop: Arc<AtomicBool>) -> Vec<JoinHandle<()>> {
    mixer.set_output_gain(OUT_LOCAL, cfg.volume_local);
    mixer.set_output_gain(OUT_VIRTUAL, cfg.volume_virtual);
    let mut v = vec![
        spawn_local(mixer.clone(), stop.clone()),
        spawn_sink_feed(mixer, stop.clone()),
    ];
    if mic_feed_needed(cfg) {
        let mic = (cfg.mix_mic && !cfg.input_device.is_empty()).then(|| cfg.input_device.clone());
        v.push(spawn_mic_mix(mic, stop));
    }
    v
}

/// Non-blocking writer into a pipe-source FIFO. Drops data while nobody listens.
struct Fifo(Option<std::fs::File>, std::path::PathBuf);

impl Fifo {
    fn new(name: &str) -> Self {
        Fifo(None, fifo_path(name))
    }
    fn write(&mut self, samples: &[f32]) {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if self.0.is_none() {
            self.0 = std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(0o4000) // O_NONBLOCK
                .open(&self.1)
                .ok();
        }
        let Some(f) = self.0.as_mut() else { return };
        let mut bytes = Vec::with_capacity(samples.len() * 4);
        for s in samples {
            bytes.extend_from_slice(&s.clamp(-1.0, 1.0).to_le_bytes());
        }
        if let Err(e) = f.write_all(&bytes) {
            if e.kind() != std::io::ErrorKind::WouldBlock {
                self.0 = None; // reader went away: reopen next time
            }
        }
    }
}

fn spec() -> Spec {
    Spec { format: Format::F32le, channels: 2, rate: RATE }
}

/// The soundboard-only feed behind the "EasyBoard Sink" input, paced at real time.
fn spawn_sink_feed(mixer: Arc<Mixer>, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    thread::Builder::new()
        .name("easyboard-sink".into())
        .spawn(move || {
            let mut fifo = Fifo::new("Sink");
            let mut frames = vec![0f32; CHUNK_FRAMES * 2];
            let period = std::time::Duration::from_millis(20);
            let mut next = std::time::Instant::now();
            mixer.set_output_active(OUT_VIRTUAL, true);
            while !stop.load(Ordering::SeqCst) {
                mixer.render(OUT_VIRTUAL, &mut frames, RATE);
                fifo.write(&frames);
                next += period;
                let now = std::time::Instant::now();
                if next > now {
                    thread::sleep(next - now);
                } else {
                    next = now;
                }
            }
            mixer.set_output_active(OUT_VIRTUAL, false);
        })
        .expect("spawn audio thread")
}

/// "EasyBoard Mic": real microphone (at its own volume, if one is chosen) + the EasyBoard Sink
/// input (at its volume) + the routed apps, summed and written to the second pipe source.
fn spawn_mic_mix(mic: Option<String>, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    thread::Builder::new()
        .name("easyboard-micmix".into())
        .spawn(move || {
            let bytes_per_chunk = (CHUNK_FRAMES * 2 * 4) as u32;
            let attr = BufferAttr {
                maxlength: u32::MAX, tlength: u32::MAX, prebuf: u32::MAX,
                minreq: u32::MAX, fragsize: bytes_per_chunk,
            };
            let mut fifo = Fifo::new("Mic");
            while !stop.load(Ordering::SeqCst) {
                let open = |dev: &str, name: &str| {
                    Simple::new(None, "EasyBoard", Direction::Record, Some(dev), name, &spec(), None, Some(&attr))
                };
                let m = match mic.as_deref().map(|d| open(d, "EasyBoard microphone")).transpose() {
                    Ok(m) => m,
                    Err(e) => {
                        log::warn!("mic mix: cannot open the microphone: {e:?}");
                        thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };
                let b = match open(SOUNDBOARD_SOURCE, "EasyBoard soundboard") {
                    Ok(b) => b,
                    Err(e) => {
                        log::warn!("mic mix: cannot open the soundboard input: {e:?}");
                        thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };
                let mut mb = vec![0u8; bytes_per_chunk as usize];
                let mut bb = vec![0u8; bytes_per_chunk as usize];
                let mut out = vec![0f32; CHUNK_FRAMES * 2];
                let f = |buf: &[u8], i: usize| f32::from_le_bytes(buf[i * 4..i * 4 + 4].try_into().unwrap());
                while !stop.load(Ordering::SeqCst) {
                    if m.as_ref().map(|m| m.read(&mut mb).is_err()).unwrap_or(false) || b.read(&mut bb).is_err() {
                        break;
                    }
                    for (i, o) in out.iter_mut().enumerate() {
                        *o = f(&bb, i) + if m.is_some() { f(&mb, i) } else { 0.0 };
                    }
                    super::apps::mix_into(&mut out, RATE);
                    fifo.write(&out);
                }
            }
        })
        .expect("spawn audio thread")
}

/// The app's own audio ("EasyBoard" in the Applications tab) on the default output.
fn spawn_local(mixer: Arc<Mixer>, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    let out = OUT_LOCAL;
    thread::Builder::new()
        .name("easyboard-out".into())
        .spawn(move || {
            let bytes_per_chunk = (CHUNK_FRAMES * 2 * 4) as u32;
            let attr = BufferAttr {
                maxlength: u32::MAX,
                tlength: bytes_per_chunk * 2,
                prebuf: u32::MAX,
                minreq: u32::MAX,
                fragsize: u32::MAX,
            };
            while !stop.load(Ordering::SeqCst) {
                let simple = Simple::new(
                    None, "EasyBoard", Direction::Playback, None, "EasyBoard", &spec(), None, Some(&attr),
                );
                let simple = match simple {
                    Ok(s) => s,
                    Err(e) => {
                        log::warn!("output: cannot open stream: {e}");
                        thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };
                mixer.set_output_active(out, true);
                let mut frames = vec![0f32; CHUNK_FRAMES * 2];
                let mut bytes = Vec::with_capacity(frames.len() * 4);
                while !stop.load(Ordering::SeqCst) {
                    mixer.render(out, &mut frames, RATE);
                    bytes.clear();
                    for s in &frames {
                        bytes.extend_from_slice(&s.to_le_bytes());
                    }
                    if let Err(e) = simple.write(&bytes) {
                        log::warn!("output: write failed: {e}");
                        break;
                    }
                }
                mixer.set_output_active(out, false);
            }
        })
        .expect("spawn audio thread")
}

/// Records the microphone (`dev`, empty = default input) into `buf` as interleaved stereo f32
/// until `stop` is set. Used by the sound editor's "Record".
pub fn record_loop(
    dev: String,
    buf: Arc<Mutex<Vec<f32>>>,
    rate: Arc<std::sync::atomic::AtomicU32>,
    err: Arc<Mutex<String>>,
    stop: Arc<AtomicBool>,
) {
    let bytes = (CHUNK_FRAMES * 2 * 4) as u32;
    let attr = BufferAttr { maxlength: u32::MAX, tlength: u32::MAX, prebuf: u32::MAX, minreq: u32::MAX, fragsize: bytes };
    let device = if dev.is_empty() { None } else { Some(dev.as_str()) };
    let simple = match Simple::new(None, "EasyBoard", Direction::Record, device, "EasyBoard recording", &spec(), None, Some(&attr)) {
        Ok(s) => s,
        Err(e) => {
            *err.lock() = format!("Could not open the microphone: {e}");
            return;
        }
    };
    rate.store(RATE, Ordering::SeqCst);
    let mut raw = vec![0u8; bytes as usize];
    while !stop.load(Ordering::SeqCst) {
        if simple.read(&mut raw).is_err() {
            *err.lock() = "The microphone stopped.".into();
            break;
        }
        let mut b = buf.lock();
        if b.len() > super::MAX_RECORD_SAMPLES {
            break;
        }
        b.extend(raw.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])));
    }
}
