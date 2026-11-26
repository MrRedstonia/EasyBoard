//! Windows / macOS backend built on cpal.
//!
//! These systems cannot create virtual devices from user space, so the user
//! installs a virtual cable (VB-Audio Cable on Windows and macOS).
//! EasyBoard plays the soundboard into the cable's *output* device and mixes the
//! selected microphone into it, then apps pick the cable's *input* side.

use super::InputDevice;
use crate::{
    config::Config,
    mixer::{Mixer, OUT_LOCAL, OUT_VIRTUAL},
};
use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    Device, FromSample, SampleFormat, SizedSample, Stream, StreamConfig,
};
use parking_lot::Mutex;
use std::{
    collections::VecDeque,
    sync::{atomic::{AtomicBool, Ordering}, Arc},
    thread::{self, JoinHandle},
    time::Duration,
};

/// The device App routing creates on macOS (named in cpp/apptap_mac.mm) to capture an app. It is
/// private, which hides it from other apps but not from EasyBoard itself: keep it out of the lists.
fn is_routing_device(name: &str) -> bool {
    name.starts_with("EasyBoard App Routing")
}

pub fn list_inputs() -> Vec<InputDevice> {
    let host = cpal::default_host();
    host.input_devices()
        .map(|it| {
            it.filter_map(|d| d.name().ok())
                .filter(|n| !is_routing_device(n))
                // the virtual cable's own end is not a microphone
                .filter(|n| {
                    let l = n.to_ascii_lowercase();
                    !(l.contains("vb-audio") || l.contains("vb-cable") || l.contains("cable output"))
                })
                .map(|n| InputDevice { id: n.clone(), label: n })
                .collect()
        })
        .unwrap_or_default()
}

pub fn list_virtual_candidates() -> Vec<String> {
    let host = cpal::default_host();
    host.output_devices()
        .map(|it| it.filter_map(|d| d.name().ok()).filter(|n| !is_routing_device(n)).collect())
        .unwrap_or_default()
}

pub fn prepare_virtual(cfg: &Config) -> Result<(), String> {
    if cfg.virtual_device.is_empty() {
        return Err("No virtual cable selected. Install VB-Cable and choose it in Settings.".into());
    }
    Ok(())
}

pub fn shutdown_virtual() {}

/// The microphone and routed apps are mixed into the cable stream, which always runs.
pub fn mic_feed_needed(_cfg: &Config) -> bool {
    false
}

/// No system-level mute here: the caller lowers the volume instead.
pub fn set_mute(_which: usize, _on: bool) -> bool {
    false
}

pub fn get_mutes() -> Option<[bool; 3]> {
    None
}

static MIC_GAIN: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0x3f80_0000); // 1.0

/// Windows/macOS: the microphone is mixed in-app, so its level is applied here.
pub fn set_mic_volume(v: f32) {
    MIC_GAIN.store(v.max(0.0).to_bits(), Ordering::Relaxed);
}

fn find_output(name: &str) -> Option<Device> {
    let host = cpal::default_host();
    host.output_devices().ok()?.find(|d| d.name().map(|n| n == name).unwrap_or(false))
}

fn find_input(name: &str) -> Option<Device> {
    let host = cpal::default_host();
    host.input_devices().ok()?.find(|d| d.name().map(|n| n == name).unwrap_or(false))
}

pub fn start_outputs(mixer: Arc<Mixer>, cfg: &Config, stop: Arc<AtomicBool>) -> Vec<JoinHandle<()>> {
    mixer.set_output_gain(OUT_LOCAL, cfg.volume_local);
    mixer.set_output_gain(OUT_VIRTUAL, cfg.volume_virtual);

    let mic = Arc::new(MicBuffer::default());

    let local = {
        let (mixer, stop) = (mixer.clone(), stop.clone());
        thread::spawn(move || {
            let dev = cpal::default_host().default_output_device();
            run_output(mixer, OUT_LOCAL, dev, None, stop);
        })
    };

    let virt = {
        let (mixer, stop, mic) = (mixer.clone(), stop.clone(), mic.clone());
        let dev_name = cfg.virtual_device.clone();
        thread::spawn(move || {
            let dev = if dev_name.is_empty() { None } else { find_output(&dev_name) };
            run_output(mixer, OUT_VIRTUAL, dev, Some(mic), stop);
        })
    };

    let mut handles = vec![local, virt];

    if cfg.mix_mic && !cfg.input_device.is_empty() {
        let name = cfg.input_device.clone();
        handles.push(thread::spawn(move || run_mic(name, mic, stop)));
    }
    handles
}

// ---------------------------------------------------------------- output ----

fn run_output(
    mixer: Arc<Mixer>,
    out: usize,
    device: Option<Device>,
    mic: Option<Arc<MicBuffer>>,
    stop: Arc<AtomicBool>,
) {
    let Some(device) = device else {
        log::warn!("output {out}: no device available");
        return;
    };
    let Ok(supported) = device.default_output_config() else { return };
    let format = supported.sample_format();
    let config: StreamConfig = supported.config();

    let stream = match format {
        SampleFormat::F32 => build::<f32>(&device, &config, mixer.clone(), out, mic),
        SampleFormat::I16 => build::<i16>(&device, &config, mixer.clone(), out, mic),
        SampleFormat::U16 => build::<u16>(&device, &config, mixer.clone(), out, mic),
        other => {
            log::error!("unsupported sample format {other:?}");
            return;
        }
    };
    let Some(stream) = stream else { return };
    if stream.play().is_err() {
        return;
    }
    mixer.set_output_active(out, true);
    while !stop.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(100));
    }
    mixer.set_output_active(out, false);
    drop(stream);
}

fn build<T>(
    device: &Device,
    config: &StreamConfig,
    mixer: Arc<Mixer>,
    out: usize,
    mic: Option<Arc<MicBuffer>>,
) -> Option<Stream>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = config.channels as usize;
    let rate = config.sample_rate.0;
    let mut scratch: Vec<f32> = Vec::new();

    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| {
                let frames = data.len() / channels;
                scratch.resize(frames * 2, 0.0);
                mixer.render(out, &mut scratch, rate);
                if let Some(mic) = &mic {
                    // the virtual cable (what others hear): microphone + routed apps
                    mic.mix_into(&mut scratch, rate);
                    super::apps::mix_into(&mut scratch, rate);
                }
                for (i, frame) in data.chunks_exact_mut(channels).enumerate() {
                    let (l, r) = (scratch[i * 2], scratch[i * 2 + 1]);
                    for (c, s) in frame.iter_mut().enumerate() {
                        let v = match (channels, c) {
                            (1, _) => (l + r) * 0.5,
                            (_, 0) => l,
                            (_, 1) => r,
                            _ => 0.0,
                        };
                        *s = T::from_sample(v.clamp(-1.0, 1.0));
                    }
                }
            },
            |e| log::error!("audio stream error: {e}"),
            None,
        )
        .ok()
}

// ------------------------------------------------------------ microphone ----

/// Small FIFO carrying microphone audio to the virtual output stream.
#[derive(Default)]
struct MicBuffer {
    inner: Mutex<MicInner>,
}

#[derive(Default)]
struct MicInner {
    queue: VecDeque<f32>, // interleaved stereo
    in_rate: u32,
    frac: f64,
}

impl MicBuffer {
    fn push(&self, stereo: &[f32], in_rate: u32) {
        let mut g = self.inner.lock();
        g.in_rate = in_rate;
        g.queue.extend(stereo.iter().copied());
        let max = in_rate as usize * 2 / 5; // ~200 ms of stereo samples
        while g.queue.len() > max {
            g.queue.pop_front();
            g.queue.pop_front();
        }
    }

    /// Adds buffered microphone audio to `buf`, resampling linearly if needed.
    fn mix_into(&self, buf: &mut [f32], out_rate: u32) {
        let mut g = self.inner.lock();
        if g.in_rate == 0 {
            return;
        }
        let step = g.in_rate as f64 / out_rate as f64;
        let gain = f32::from_bits(MIC_GAIN.load(Ordering::Relaxed));
        for frame in buf.chunks_exact_mut(2) {
            if g.queue.len() < 4 {
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

fn run_mic(name: String, mic: Arc<MicBuffer>, stop: Arc<AtomicBool>) {
    let Some(device) = find_input(&name) else {
        log::warn!("microphone '{name}' not found");
        return;
    };
    let Ok(supported) = device.default_input_config() else { return };
    let format = supported.sample_format();
    let config: StreamConfig = supported.config();

    let stream = match format {
        SampleFormat::F32 => build_in::<f32>(&device, &config, mic),
        SampleFormat::I16 => build_in::<i16>(&device, &config, mic),
        SampleFormat::U16 => build_in::<u16>(&device, &config, mic),
        _ => None,
    };
    let Some(stream) = stream else { return };
    if stream.play().is_err() {
        return;
    }
    while !stop.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(100));
    }
    drop(stream);
}

fn build_in<T>(device: &Device, config: &StreamConfig, mic: Arc<MicBuffer>) -> Option<Stream>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    let rate = config.sample_rate.0;
    let mut tmp: Vec<f32> = Vec::new();
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                tmp.clear();
                for frame in data.chunks_exact(channels) {
                    let l = f32::from_sample_(frame[0]);
                    let r = if channels > 1 { f32::from_sample_(frame[1]) } else { l };
                    tmp.push(l);
                    tmp.push(r);
                }
                mic.push(&tmp, rate);
            },
            |e| log::error!("microphone stream error: {e}"),
            None,
        )
        .ok()
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
    let host = cpal::default_host();
    let device = if dev.is_empty() { host.default_input_device() } else { find_input(&dev).or_else(|| host.default_input_device()) };
    let Some(device) = device else {
        *err.lock() = "No microphone found.".into();
        return;
    };
    let Ok(supported) = device.default_input_config() else {
        *err.lock() = "Could not open the microphone.".into();
        return;
    };
    let format = supported.sample_format();
    let config: StreamConfig = supported.config();
    rate.store(config.sample_rate.0, Ordering::SeqCst);
    let stream = match format {
        SampleFormat::F32 => build_rec::<f32>(&device, &config, buf),
        SampleFormat::I16 => build_rec::<i16>(&device, &config, buf),
        SampleFormat::U16 => build_rec::<u16>(&device, &config, buf),
        _ => None,
    };
    let Some(stream) = stream else {
        *err.lock() = "Could not open the microphone.".into();
        return;
    };
    if stream.play().is_err() {
        *err.lock() = "Could not start the microphone.".into();
        return;
    }
    while !stop.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(50));
    }
    drop(stream);
}

fn build_rec<T>(device: &Device, config: &StreamConfig, buf: Arc<Mutex<Vec<f32>>>) -> Option<Stream>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                let mut b = buf.lock();
                if b.len() > super::MAX_RECORD_SAMPLES {
                    return;
                }
                for frame in data.chunks_exact(channels) {
                    let l = f32::from_sample_(frame[0]);
                    let r = if channels > 1 { f32::from_sample_(frame[1]) } else { l };
                    b.push(l);
                    b.push(r);
                }
            },
            |e| log::error!("recording stream error: {e}"),
            None,
        )
        .ok()
}
