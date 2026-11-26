//! Platform audio: output streams, microphone listing, virtual input device.
//!
//! * Linux   – PulseAudio API (works on PipeWire via pipewire-pulse). EasyBoard
//!             creates the "EasyBoard Sink" input itself with `pactl`.
//! * Windows / macOS – cpal. A virtual cable driver (VB-Cable) must be
//!             installed; EasyBoard plays into it and mixes the microphone in.

use crate::{config::Config, mixer::Mixer};
use std::{
    sync::{atomic::{AtomicBool, Ordering}, Arc},
    thread::JoinHandle,
};

pub mod apps;

#[cfg(target_os = "linux")]
mod pulse;
#[cfg(target_os = "linux")]
use pulse as platform;

#[cfg(not(target_os = "linux"))]
mod cpal_out;
#[cfg(not(target_os = "linux"))]
use cpal_out as platform;

#[derive(Clone, Debug)]
pub struct InputDevice {
    /// Stable identifier stored in the config.
    pub id: String,
    /// Human readable name shown in the UI.
    pub label: String,
}

pub fn list_inputs() -> Vec<InputDevice> {
    platform::list_inputs()
}

/// Names of devices that look like a virtual cable (Windows/macOS) so the UI
/// can offer them. Empty on Linux where EasyBoard creates its own device.
pub fn list_virtual_candidates() -> Vec<String> {
    platform::list_virtual_candidates()
}

/// Creates / refreshes the virtual input ("EasyBoard Sink") where supported.
pub fn prepare_virtual(cfg: &Config) -> Result<(), String> {
    platform::prepare_virtual(cfg)
}

/// Linux: whether the "EasyBoard Mic" input has to exist (microphone mixed in or apps routed).
/// Always false on Windows/macOS, where nothing has to be restarted for it.
pub fn mic_feed_needed(cfg: &Config) -> bool {
    platform::mic_feed_needed(cfg)
}

/// Sets the level of the "EasyBoard Mic" input (Linux only; no-op elsewhere).
pub fn set_mic_volume(v: f32) {
    platform::set_mic_volume(v);
}

/// System-level mute of 0 = personal stream, 1 = sink, 2 = mic. False = unsupported / failed.
pub fn set_mute(which: usize, on: bool) -> bool {
    platform::set_mute(which, on)
}

pub fn get_mutes() -> Option<[bool; 3]> {
    platform::get_mutes()
}

/// At most five minutes of stereo samples per recording.
pub(crate) const MAX_RECORD_SAMPLES: usize = 48_000 * 2 * 300;

/// A running microphone recording (sound editor). `finish` stops it and returns the audio.
pub struct Recorder {
    stop: Arc<AtomicBool>,
    buf: Arc<parking_lot::Mutex<Vec<f32>>>,
    rate: Arc<std::sync::atomic::AtomicU32>,
    err: Arc<parking_lot::Mutex<String>>,
    thread: Option<JoinHandle<()>>,
}

/// Starts recording from `device` (a name from `list_inputs`, empty = the default input).
pub fn start_recording(device: &str) -> Recorder {
    let stop = Arc::new(AtomicBool::new(false));
    let buf = Arc::new(parking_lot::Mutex::new(Vec::new()));
    let rate = Arc::new(std::sync::atomic::AtomicU32::new(48_000));
    let err = Arc::new(parking_lot::Mutex::new(String::new()));
    let (d, b, r, e, s) = (device.to_string(), buf.clone(), rate.clone(), err.clone(), stop.clone());
    let thread = std::thread::Builder::new()
        .name("easyboard-record".into())
        .spawn(move || platform::record_loop(d, b, r, e, s))
        .ok();
    Recorder { stop, buf, rate, err, thread }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl Recorder {
    pub fn seconds(&self) -> f64 {
        self.buf.lock().len() as f64 / 2.0 / self.rate.load(Ordering::SeqCst).max(1) as f64
    }
    /// Peak of the most recent ~50 ms, 0..=1.
    pub fn level(&self) -> f32 {
        let b = self.buf.lock();
        let from = b.len().saturating_sub(4800);
        b[from..].iter().fold(0f32, |m, v| m.max(v.abs())).min(1.0)
    }
    /// Peaks of the last `count` slices of 50 ms (oldest first), for the live waveform.
    pub fn peaks(&self, count: usize) -> Vec<f32> {
        let b = self.buf.lock();
        let rate = self.rate.load(Ordering::SeqCst).max(1) as usize;
        let slice = (rate / 20).max(1) * 2; // samples per 50 ms (stereo)
        let total = b.len() / slice;
        let first = total.saturating_sub(count);
        (first..total)
            .map(|i| b[i * slice..(i + 1) * slice].iter().fold(0f32, |m, v| m.max(v.abs())).min(1.0))
            .collect()
    }
    pub fn error(&self) -> String {
        self.err.lock().clone()
    }
    pub fn finish(mut self) -> Result<crate::decode::Decoded, String> {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        let e = self.err.lock().clone();
        let samples = std::mem::take(&mut *self.buf.lock());
        if samples.is_empty() {
            return Err(if e.is_empty() { "Nothing was recorded.".into() } else { e });
        }
        Ok(crate::decode::Decoded { samples, rate: self.rate.load(Ordering::SeqCst) })
    }
}

pub fn shutdown_virtual() {
    platform::shutdown_virtual();
}

/// Running output streams. Dropping (or `stop`) shuts them down.
pub struct Outputs {
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
}

impl Outputs {
    pub fn start(mixer: Arc<Mixer>, cfg: &Config) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let threads = platform::start_outputs(mixer, cfg, stop.clone());
        Self { stop, threads }
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

impl Drop for Outputs {
    fn drop(&mut self) {
        self.stop();
    }
}
