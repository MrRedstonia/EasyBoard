//! Lock-light multi-voice mixer shared by every output stream.
//!
//! Each output (0 = what you hear, 1 = what others hear) keeps its own read
//! cursor per voice, so the two device clocks never have to agree.

use crate::decode::Decoded;
use parking_lot::Mutex;
use std::sync::{
    atomic::{AtomicBool, AtomicU32, Ordering},
    Arc,
};

pub const OUT_LOCAL: usize = 0;
pub const OUT_VIRTUAL: usize = 1;

struct Voice {
    sound_id: String,
    data: Arc<Decoded>,
    gain: f32,
    looping: bool,
    pos: [f64; 2],
    done: [bool; 2],
}

pub struct Mixer {
    voices: Mutex<Vec<Voice>>,
    active: [AtomicBool; 2],
    out_gain: [AtomicU32; 2],
    loop_all: AtomicBool,
}

impl Mixer {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            voices: Mutex::new(Vec::new()),
            active: [AtomicBool::new(false), AtomicBool::new(false)],
            out_gain: [AtomicU32::new(1f32.to_bits()), AtomicU32::new(1f32.to_bits())],
            loop_all: AtomicBool::new(false),
        })
    }

    pub fn set_output_active(&self, out: usize, on: bool) {
        self.active[out].store(on, Ordering::SeqCst);
    }

    pub fn set_output_gain(&self, out: usize, gain: f32) {
        self.out_gain[out].store(gain.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_loop_all(&self, on: bool) {
        self.loop_all.store(on, Ordering::SeqCst);
    }

    pub fn loop_all(&self) -> bool {
        self.loop_all.load(Ordering::SeqCst)
    }

    pub fn play(&self, sound_id: &str, data: Arc<Decoded>, gain: f32, looping: bool) {
        self.voices.lock().push(Voice {
            sound_id: sound_id.to_string(),
            data,
            gain,
            looping,
            pos: [0.0; 2],
            done: [false; 2],
        });
    }

    /// Plays on your own output only (the "what others hear" input never gets it).
    pub fn play_local(&self, sound_id: &str, data: Arc<Decoded>, gain: f32) {
        self.voices.lock().push(Voice {
            sound_id: sound_id.to_string(),
            data,
            gain,
            looping: false,
            pos: [0.0; 2],
            done: [false, true],
        });
    }

    /// Like `play_local`, but starts at `start` (0..1 of the sound) and can loop (the loop restarts
    /// from the beginning of the sound).
    pub fn play_local_from(&self, sound_id: &str, data: Arc<Decoded>, gain: f32, looping: bool, start: f64) {
        let at = start.clamp(0.0, 0.999) * data.frames() as f64;
        self.voices.lock().push(Voice {
            sound_id: sound_id.to_string(),
            data,
            gain,
            looping,
            pos: [at; 2],
            done: [false, true],
        });
    }

    pub fn stop_all(&self) {
        self.voices.lock().clear();
    }

    pub fn stop(&self, sound_id: &str) {
        self.voices.lock().retain(|v| v.sound_id != sound_id);
    }

    pub fn set_loop(&self, sound_id: &str, on: bool) {
        for v in self.voices.lock().iter_mut().filter(|v| v.sound_id == sound_id) {
            v.looping = on;
        }
    }

    pub fn is_playing(&self, sound_id: &str) -> bool {
        self.voices.lock().iter().any(|v| v.sound_id == sound_id)
    }

    /// (sound id, 0.0..=1.0 position) for every playing voice, read from whichever
    /// output is running (your speakers first).
    pub fn playing_progress(&self) -> Vec<(String, f32)> {
        let out = if self.active[OUT_LOCAL].load(Ordering::SeqCst) { OUT_LOCAL } else { OUT_VIRTUAL };
        self.voices
            .lock()
            .iter()
            .map(|v| {
                let frames = v.data.frames().max(1) as f64;
                (v.sound_id.clone(), (v.pos[out] / frames).clamp(0.0, 1.0) as f32)
            })
            .collect()
    }

    pub fn playing_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.voices.lock().iter().map(|v| v.sound_id.clone()).collect();
        ids.sort();
        ids.dedup();
        ids
    }

    /// Fill `buf` (interleaved stereo) for output `out` running at `out_rate`.
    pub fn render(&self, out: usize, buf: &mut [f32], out_rate: u32) {
        buf.fill(0.0);
        let master = f32::from_bits(self.out_gain[out].load(Ordering::Relaxed));
        let loop_all = self.loop_all.load(Ordering::Relaxed);
        let mut voices = self.voices.lock();

        for v in voices.iter_mut() {
            if v.done[out] {
                continue;
            }
            let looping = v.looping || loop_all;
            let frames = v.data.frames();
            let step = v.data.rate as f64 / out_rate as f64;
            let gain = v.gain * master;
            let s = &v.data.samples;

            for frame in buf.as_chunks_mut::<2>().0 {
                let mut i = v.pos[out] as usize;
                if i >= frames {
                    if looping {
                        v.pos[out] %= frames as f64;
                        i = v.pos[out] as usize;
                    } else {
                        v.done[out] = true;
                        break;
                    }
                }
                let frac = (v.pos[out] - i as f64) as f32;
                let j = if i + 1 < frames { i + 1 } else if looping { 0 } else { i };
                frame[0] += (s[i * 2] + (s[j * 2] - s[i * 2]) * frac) * gain;
                frame[1] += (s[i * 2 + 1] + (s[j * 2 + 1] - s[i * 2 + 1]) * frac) * gain;
                v.pos[out] += step;
            }
        }

        // A voice is finished once every *active* output has played it out.
        let act = [
            self.active[0].load(Ordering::SeqCst),
            self.active[1].load(Ordering::SeqCst),
        ];
        voices.retain(|v| (0..2).any(|o| act[o] && !v.done[o]));
        drop(voices);

        for x in buf.iter_mut() {
            *x = x.clamp(-1.0, 1.0);
        }
    }
}
