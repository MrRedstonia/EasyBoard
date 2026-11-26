//! The sound editor's working audio: an in-memory buffer with undo / redo and a clipboard.
//! Structural edits (delete, cut, paste, pause, recording) change the buffer; the effects
//! (speed, pitch, volume, fades, reverse, compressor) stay pending and are applied when
//! previewing or saving (see `fx::render`).

use crate::{decode::Decoded, fx};
use serde_json::{json, Value};
use std::sync::Arc;

const HISTORY: usize = 50;
const MAX_PAUSE_SECONDS: f64 = 600.0;

struct Snap {
    buf: Option<Arc<Decoded>>,
    start: f64,
    end: f64,
}

#[derive(Default)]
pub struct Session {
    pub buf: Option<Arc<Decoded>>,
    pub path: String,
    undo: Vec<Snap>,
    redo: Vec<Snap>,
    clip: Option<Arc<Decoded>>,
}

fn frames_of(d: &Option<Arc<Decoded>>) -> usize {
    d.as_ref().map(|d| d.frames()).unwrap_or(0)
}

impl Session {
    pub fn open(&mut self, data: Arc<Decoded>, path: &str) {
        self.buf = Some(data);
        self.path = path.to_string();
        self.undo.clear();
        self.redo.clear();
    }

    pub fn clear(&mut self) {
        self.buf = None;
        self.path.clear();
        self.undo.clear();
        self.redo.clear();
    }

    pub fn data(&self) -> Option<Arc<Decoded>> {
        self.buf.clone().filter(|d| d.frames() > 0)
    }

    pub fn state(&self, start: f64, end: f64) -> Value {
        let (n, rate) = self.buf.as_ref().map(|d| (d.frames(), d.rate)).unwrap_or((0, 48_000));
        json!({
            "duration": n as f64 / rate.max(1) as f64,
            "peaks": self.buf.as_ref().map(|d| fx::peaks(d, 700)).unwrap_or_default(),
            "canUndo": !self.undo.is_empty(),
            "canRedo": !self.redo.is_empty(),
            "hasClip": self.clip.is_some(),
            "loaded": self.buf.is_some(),
            "path": self.path,
            "name": std::path::Path::new(&self.path).file_name().and_then(|n| n.to_str()).unwrap_or(""),
            "start": start,
            "end": end,
        })
    }

    fn push_undo(&mut self, start: f64, end: f64) {
        self.undo.push(Snap { buf: self.buf.clone(), start, end });
        if self.undo.len() > HISTORY {
            self.undo.remove(0);
        }
        self.redo.clear();
    }

    /// Inserts `ins` at fraction `at` (resampled to the buffer's rate). Returns the new crop.
    pub fn insert_audio(&mut self, ins: &Decoded, at: f64, start: f64, end: f64) -> (f64, f64) {
        let n = frames_of(&self.buf);
        if n > 0 {
            self.push_undo(start, end); // putting audio into an empty editor is not something to undo
        }
        let Some(cur) = self.buf.clone().filter(|d| d.frames() > 0) else {
            self.buf = Some(Arc::new(Decoded { samples: ins.samples.clone(), rate: ins.rate }));
            return (0.0, 1.0);
        };
        let ins = fx::to_rate(ins, cur.rate);
        let len = ins.frames();
        let at_f = ((at.clamp(0.0, 1.0)) * n as f64).round().min(n as f64);
        self.buf = Some(Arc::new(fx::insert_at(&cur, at_f as usize, &ins)));
        let new_n = (n + len) as f64;
        let (cs, ce) = (start * n as f64, end * n as f64);
        let ncs = if cs > at_f { cs + len as f64 } else { cs };
        let nce = if ce >= at_f { ce + len as f64 } else { ce };
        ((ncs / new_n).clamp(0.0, 1.0), (nce / new_n).clamp(0.0, 1.0))
    }

    /// Bakes the selection's own effects into the buffer (the track-wide effects stay pending).
    /// Returns the new crop (start, end).
    pub fn apply_fx(&mut self, crop: (f64, f64), sel: fx::SelFx) -> Result<(f64, f64), String> {
        let cur = self.buf.clone().filter(|d| d.frames() > 0).ok_or("There is nothing to edit.")?;
        let n = cur.frames() as f64;
        let (a, b, sp) = sel;
        let (ra, rb) = (a.max(crop.0), b.min(crop.1));
        let (out, delta) = fx::bake_region(&cur, &sp, ra, rb).ok_or("Nothing to apply the effect to.")?;
        self.push_undo(crop.0, crop.1);
        let new_n = out.frames().max(1) as f64;
        self.buf = Some(Arc::new(out));
        let ns = crop.0 * n;
        let ne = crop.1 * n + delta as f64;
        Ok(((ns / new_n).clamp(0.0, 1.0), (ne / new_n).clamp(0.0, 1.0)))
    }

    /// One structural edit. `a`/`b` are fractions of the whole buffer, `arg` the pause in ms.
    /// Returns the crop (start, end) to use afterwards.
    pub fn edit(&mut self, op: &str, a: f64, b: f64, arg: f64, start: f64, end: f64) -> Result<(f64, f64), String> {
        let n = frames_of(&self.buf);
        let fa = (a.clamp(0.0, 1.0) * n as f64).round() as usize;
        let fb = (b.clamp(0.0, 1.0) * n as f64).round() as usize;
        match op {
            "copy" | "cut" | "delete" => {
                if fb <= fa || n == 0 {
                    return Err("Select a part of the audio first.".into());
                }
                let cur = self.buf.clone().unwrap();
                if op != "delete" {
                    self.clip = Some(Arc::new(fx::slice(&cur, fa, fb)));
                }
                if op == "copy" {
                    return Ok((start, end));
                }
                self.push_undo(start, end);
                let removed = (fb - fa) as f64;
                self.buf = Some(Arc::new(fx::delete_range(&cur, fa, fb)));
                let new_n = (n - (fb - fa)) as f64;
                if new_n <= 0.0 {
                    return Ok((0.0, 1.0));
                }
                let map = |p: f64| {
                    let p = p * n as f64;
                    if p <= fa as f64 { p } else if p >= fb as f64 { p - removed } else { fa as f64 }
                };
                let (ns, ne) = (map(start) / new_n, map(end) / new_n);
                if ne - ns < 0.001 { Ok((0.0, 1.0)) } else { Ok((ns, ne)) }
            }
            "paste" => {
                let clip = self.clip.clone().ok_or("The clipboard is empty. Copy a part of the audio first.")?;
                Ok(self.insert_audio(&clip, a, start, end))
            }
            "silence" => {
                let rate = self.buf.as_ref().map(|d| d.rate).unwrap_or(48_000);
                let secs = (arg / 1000.0).clamp(0.0, MAX_PAUSE_SECONDS);
                let frames = (secs * rate as f64) as usize;
                if frames == 0 {
                    return Err("Enter a pause length in milliseconds.".into());
                }
                Ok(self.insert_audio(&fx::silence(rate, frames), a, start, end))
            }
            "undo" => {
                let snap = self.undo.pop().ok_or("Nothing to undo.")?;
                self.redo.push(Snap { buf: self.buf.clone(), start, end });
                self.buf = snap.buf;
                Ok((snap.start, snap.end))
            }
            "redo" => {
                let snap = self.redo.pop().ok_or("Nothing to redo.")?;
                self.undo.push(Snap { buf: self.buf.clone(), start, end });
                self.buf = snap.buf;
                Ok((snap.start, snap.end))
            }
            _ => Err(format!("Unknown edit '{op}'.")),
        }
    }
}
