//! App routing: captures the audio of chosen applications and mixes it into "EasyBoard Mic"
//! (Linux) or the virtual cable (Windows/macOS). The apps keep playing normally, so you still
//! hear them; EasyBoard only listens in on their audio.
//!
//! * Linux   – each playback stream (sink input) of the app is recorded on its own with
//!             `parec --monitor-stream` (PulseAudio and pipewire-pulse).
//! * Windows – process loopback capture (WASAPI, Windows 10 2004 / build 19041 or newer).
//! * macOS   – Core Audio process taps (macOS 14.2 or newer).

use parking_lot::Mutex;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{atomic::{AtomicBool, Ordering}, Arc},
    time::Duration,
};

#[cfg(target_os = "linux")]
#[path = "apps_linux.rs"]
mod platform;
#[cfg(not(target_os = "linux"))]
#[path = "apps_native.rs"]
mod platform;

/// An application currently playing audio, as offered in the "+" menu.
#[derive(Clone, Debug)]
pub struct AudioApp {
    /// Stable identity, stored in the config (`AppRoute::key`).
    pub key: String,
    pub name: String,
    /// "theme:<icon name>", "file:<path>" or "".
    pub icon: String,
}

/// One capturable piece of an app's audio (Linux: a sink input; Windows/macOS: a process).
pub(crate) struct Target {
    pub id: u64,
    pub app: AudioApp,
    /// Actually producing sound right now (not paused / corked).
    pub active: bool,
}

/// Apps that are playing audio right now, one entry per app, EasyBoard itself excluded.
pub fn list_playing() -> Vec<AudioApp> {
    let mut seen = HashSet::new();
    let mut out: Vec<AudioApp> = platform::targets()
        .into_iter()
        .filter(|t| t.active)
        .filter(|t| seen.insert(t.app.key.clone()))
        .map(|t| t.app)
        .collect();
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

/// True where app routing can work on this system (macOS older than 14.2 cannot).
pub fn supported() -> bool {
    platform::supported()
}

// ------------------------------------------------------------ the router ----

static WANTED: Mutex<Vec<String>> = Mutex::new(Vec::new());
static STARTED: AtomicBool = AtomicBool::new(false);
/// Captured audio of every running capture, by target id.
static QUEUES: Mutex<Vec<(u64, Arc<RateQueue>)>> = Mutex::new(Vec::new());

/// Sets which apps (by key) are routed. A background thread then follows their audio streams
/// as they come and go.
pub fn set_routes(keys: Vec<String>) {
    *WANTED.lock() = keys;
    if !STARTED.swap(true, Ordering::SeqCst) {
        let _ = std::thread::Builder::new().name("easyboard-approute".into()).spawn(router);
    }
}

fn router() {
    let mut running: HashMap<u64, platform::Capture> = HashMap::new();
    loop {
        let wanted: HashSet<String> = WANTED.lock().iter().cloned().collect();
        let targets = if wanted.is_empty() { Vec::new() } else { platform::targets() };
        let keep: HashSet<u64> = targets.iter().filter(|t| wanted.contains(&t.app.key)).map(|t| t.id).collect();

        // stop captures of apps that were removed / disabled or whose stream ended
        running.retain(|id, cap| keep.contains(id) && cap.alive());
        QUEUES.lock().retain(|(id, _)| running.contains_key(id));

        let new: Vec<&Target> = targets.iter().filter(|t| keep.contains(&t.id) && !running.contains_key(&t.id)).collect();
        for t in new {
            let q = Arc::new(RateQueue::default());
            match platform::Capture::start(t.id, q.clone()) {
                Ok(cap) => {
                    log::info!("app routing: capturing {} ({})", t.app.name, t.id);
                    running.insert(t.id, cap);
                    QUEUES.lock().push((t.id, q));
                }
                Err(e) => log::warn!("app routing: cannot capture {}: {e}", t.app.name),
            }
        }
        std::thread::sleep(Duration::from_millis(if wanted.is_empty() { 1000 } else { 700 }));
    }
}

/// Level of the routed apps: follows the EasyBoard Sink / soundboard volume and its mute.
static GAIN: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0x3f80_0000); // 1.0

pub fn set_gain(v: f32) {
    GAIN.store(v.max(0.0).to_bits(), Ordering::Relaxed);
}

/// Adds the routed apps' audio to `buf` (interleaved stereo at `rate`).
pub fn mix_into(buf: &mut [f32], rate: u32) {
    let gain = f32::from_bits(GAIN.load(Ordering::Relaxed));
    for (_, q) in QUEUES.lock().iter() {
        q.mix_into(buf, rate, gain);
    }
}

// ------------------------------------------------------- jitter buffer ----

/// Interleaved stereo audio from one capture, resampled linearly when read. Holds back a little
/// audio before playing (and again after running dry) so uneven deliveries don't crackle.
#[derive(Default)]
pub(crate) struct RateQueue {
    inner: Mutex<QueueInner>,
}

#[derive(Default)]
struct QueueInner {
    queue: VecDeque<f32>,
    in_rate: u32,
    frac: f64,
    primed: bool,
}

impl RateQueue {
    pub fn push(&self, stereo: &[f32], in_rate: u32) {
        let mut g = self.inner.lock();
        g.in_rate = in_rate;
        g.queue.extend(stereo.iter().copied());
        // too far behind (clock drift, a stall): drop the oldest audio down to ~60 ms
        if g.queue.len() > in_rate as usize * 2 / 4 {
            let target = in_rate as usize * 2 * 6 / 100;
            let drop = (g.queue.len() - target) & !1;
            g.queue.drain(..drop);
        }
    }

    fn mix_into(&self, buf: &mut [f32], out_rate: u32, gain: f32) {
        let mut g = self.inner.lock();
        if g.in_rate == 0 || out_rate == 0 {
            return;
        }
        if !g.primed {
            if g.queue.len() < g.in_rate as usize * 2 * 4 / 100 {
                return; // wait for ~40 ms
            }
            g.primed = true;
        }
        let step = g.in_rate as f64 / out_rate as f64;
        for frame in buf.as_chunks_mut::<2>().0 {
            if g.queue.len() < 4 {
                g.primed = false;
                break;
            }
            let f = g.frac as f32;
            frame[0] += (g.queue[0] + (g.queue[2] - g.queue[0]) * f) * gain;
            frame[1] += (g.queue[1] + (g.queue[3] - g.queue[1]) * f) * gain;
            g.frac += step;
            while g.frac >= 1.0 && g.queue.len() >= 4 {
                g.queue.pop_front();
                g.queue.pop_front();
                g.frac -= 1.0;
            }
        }
    }
}
