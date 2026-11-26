//! Offline sound editing: crop, speed, pitch, gain (dB), fades, and a WAV writer.

use crate::decode::Decoded;
use std::{fs::File, io::Write, path::Path};

#[derive(Clone, Copy, Debug)]
pub struct Params {
    /// Crop range as fractions of the clip (0..=1).
    pub start: f64,
    pub end: f64,
    /// Playback speed multiplier (pitch is kept independent).
    pub speed: f64,
    pub gain_db: f64,
    /// Fade lengths in seconds (measured on the result).
    pub fade_in: f64,
    pub fade_out: f64,
    /// Pitch shift in semitones (speed is kept independent).
    pub pitch: f64,
    /// Play backwards.
    pub reverse: bool,
    /// Scale so the loudest peak sits just below full scale (applied before `gain_db`).
    pub compress: bool,
    /// Stereo balance: -1 = only left, 0 = center, 1 = only right.
    pub balance: f64,
}

/// Peak envelope (0..=1) in `n` buckets, for drawing the waveform.
pub fn peaks(d: &Decoded, n: usize) -> Vec<f32> {
    let frames = d.frames();
    if frames == 0 || n == 0 {
        return vec![0.0; n];
    }
    (0..n)
        .map(|i| {
            let a = i * frames / n;
            let b = (((i + 1) * frames / n).max(a + 1)).min(frames);
            let mut m = 0f32;
            for f in a..b {
                m = m.max(d.samples[f * 2].abs()).max(d.samples[f * 2 + 1].abs());
            }
            m // may exceed 1.0 after effects were baked in: the editor shows that as clipping
        })
        .collect()
}

type Frame = [f32; 2];

fn resample(x: &[Frame], ratio: f64) -> Vec<Frame> {
    // ratio > 1 reads faster: shorter and higher pitched.
    let n = x.len();
    if n < 2 {
        return x.to_vec();
    }
    let out_len = (n as f64 / ratio) as usize;
    (0..out_len)
        .map(|i| {
            let p = i as f64 * ratio;
            let i0 = (p as usize).min(n - 1);
            let i1 = (i0 + 1).min(n - 1);
            let t = (p - i0 as f64) as f32;
            [
                x[i0][0] + (x[i1][0] - x[i0][0]) * t,
                x[i0][1] + (x[i1][1] - x[i0][1]) * t,
            ]
        })
        .collect()
}

/// WSOLA time stretch: output length = input length / `tempo`, pitch unchanged.
fn stretch(x: &[Frame], tempo: f64) -> Vec<Frame> {
    let n = x.len();
    let win = 2048usize;
    let hop = win / 2;
    if n < win * 2 {
        return resample(x, tempo); // too short to bother
    }
    let out_len = (n as f64 / tempo) as usize;
    let mut out = vec![[0f32; 2]; out_len + win];
    let mut norm = vec![0f32; out_len + win];
    let hann: Vec<f32> = (0..win)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / win as f32).cos())
        .collect();
    let mono = |i: usize| -> f32 { x.get(i).map(|f| f[0] + f[1]).unwrap_or(0.0) };
    let search = 256i64;
    let mut prev: Option<usize> = None;
    let mut k = 0usize;
    while k * hop < out_len {
        let nominal = (k as f64 * hop as f64 * tempo) as i64;
        let pos = match prev {
            None => nominal.max(0) as usize,
            Some(p) => {
                // natural continuation of the previous segment
                let target = p + hop;
                let mut best = nominal.max(0) as usize;
                let mut best_score = f32::MIN;
                let lo = (nominal - search).max(0);
                let hi = nominal + search;
                let mut c = lo;
                while c <= hi {
                    let cu = c as usize;
                    let mut score = 0f32;
                    let mut i = 0;
                    while i < hop {
                        score += mono(cu + i) * mono(target + i);
                        i += 4;
                    }
                    if score > best_score {
                        best_score = score;
                        best = cu;
                    }
                    c += 2;
                }
                best
            }
        };
        if pos >= n {
            break;
        }
        let o = k * hop;
        for i in 0..win {
            if o + i >= out.len() {
                break;
            }
            let w = hann[i];
            if let Some(f) = x.get(pos + i) {
                out[o + i][0] += f[0] * w;
                out[o + i][1] += f[1] * w;
            }
            norm[o + i] += w;
        }
        prev = Some(pos);
        k += 1;
    }
    out.truncate(out_len);
    for (f, w) in out.iter_mut().zip(norm.iter()) {
        if *w > 1e-3 {
            f[0] /= w;
            f[1] /= w;
        }
    }
    out
}

/// Compressor: everything above -18 dB is squeezed 4:1 (5 ms attack, 80 ms release), then the
/// result is made as loud as possible without clipping, so quiet parts come up and peaks stay put.
fn compress(x: &mut [Frame], rate: u32) {
    const THRESHOLD: f32 = 0.125; // -18 dB
    const RATIO: f32 = 4.0;
    let rate = rate.max(1) as f32;
    let attack = (-1.0 / (0.005 * rate)).exp();
    let release = (-1.0 / (0.08 * rate)).exp();
    let mut env = 0f32;
    for f in x.iter_mut() {
        let level = f[0].abs().max(f[1].abs());
        let k = if level > env { attack } else { release };
        env = k * env + (1.0 - k) * level;
        if env > THRESHOLD {
            let g = THRESHOLD * (env / THRESHOLD).powf(1.0 / RATIO) / env;
            f[0] *= g;
            f[1] *= g;
        }
    }
    let peak = x.iter().fold(0f32, |m, f| m.max(f[0].abs()).max(f[1].abs()));
    if peak > 1e-4 {
        let makeup = 0.97 / peak;
        for f in x.iter_mut() {
            f[0] *= makeup;
            f[1] *= makeup;
        }
    }
}

/// The effects (speed, pitch, reverse, compressor, volume, balance, fades) on a run of frames.
fn effects(mut x: Vec<Frame>, p: &Params, rate: u32) -> Vec<Frame> {
    if x.is_empty() {
        return x;
    }
    let pitch_ratio = 2f64.powf(p.pitch / 12.0);
    let tempo = p.speed.clamp(0.25, 4.0) / pitch_ratio;
    if (tempo - 1.0).abs() > 0.001 {
        x = stretch(&x, tempo);
    }
    if (pitch_ratio - 1.0).abs() > 0.001 {
        x = resample(&x, pitch_ratio);
    }
    if p.reverse {
        x.reverse();
    }

    if p.compress {
        compress(&mut x, rate);
    }
    let gain = 10f32.powf(p.gain_db as f32 / 20.0);
    let bal = p.balance.clamp(-1.0, 1.0) as f32;
    let (left, right) = (1.0 - bal.max(0.0), 1.0 + bal.min(0.0));
    let rate = rate as f64;
    let n = x.len();
    let fi = ((p.fade_in * rate) as usize).min(n);
    let fo = ((p.fade_out * rate) as usize).min(n);
    for (i, f) in x.iter_mut().enumerate() {
        let mut g = gain;
        if fi > 0 && i < fi {
            g *= i as f32 / fi as f32;
        }
        if fo > 0 && i >= n - fo {
            g *= (n - i) as f32 / fo as f32;
        }
        f[0] *= g * left;
        f[1] *= g * right;
    }
    x
}

/// Crop to `p.start..p.end`, then apply the effects to everything that is left.
pub fn process_selection(d: &Decoded, p: &Params) -> Decoded {
    let frames = d.frames();
    if frames == 0 {
        return Decoded { samples: vec![], rate: d.rate };
    }
    let a = ((p.start.clamp(0.0, 1.0)) * frames as f64) as usize;
    let b = (((p.end.clamp(0.0, 1.0)) * frames as f64) as usize).max(a + 1).min(frames);
    let a = a.min(b.saturating_sub(1));
    let x: Vec<Frame> = (a..b).map(|f| [d.samples[f * 2], d.samples[f * 2 + 1]]).collect();
    let out = effects(x, p, d.rate);
    Decoded { samples: out.into_iter().flatten().collect(), rate: d.rate }
}

/// Effects for one selected part of the clip: (start, end as fractions of the whole clip, effects).
pub type SelFx = (f64, f64, Params);

/// Applies `sp` to the part `ra..rb` (fractions) and puts the result back in place. Returns the new
/// audio and the length change in frames.
pub fn bake_region(d: &Decoded, sp: &Params, ra: f64, rb: f64) -> Option<(Decoded, i64)> {
    let n = d.frames();
    let fa = (ra.clamp(0.0, 1.0) * n as f64).round() as usize;
    let fb = (rb.clamp(0.0, 1.0) * n as f64).round() as usize;
    if fb <= fa || n == 0 {
        return None;
    }
    let mut q = *sp;
    q.start = ra;
    q.end = rb;
    let out = process_selection(d, &q);
    if out.frames() == 0 {
        return None;
    }
    let delta = out.frames() as i64 - (fb - fa) as i64;
    let rest = delete_range(d, fa, fb);
    Some((insert_at(&rest, fa, &out), delta))
}

/// The finished audio: the selection's own effects first (on the selected part), then the effects
/// of the whole track and the crop on top. `only_selection` renders just the selected part (for
/// previewing a selection).
pub fn render(d: &Decoded, g: &Params, sel: Option<SelFx>, only_selection: bool) -> Result<Decoded, String> {
    let Some((a, b, sp)) = sel else {
        return Ok(process_selection(d, g));
    };
    let (ra, rb) = (a.max(g.start), b.min(g.end));
    if rb <= ra {
        return Err("The selection is outside the crop.".into());
    }
    let n = d.frames() as f64;
    let (d1, delta) = bake_region(d, &sp, ra, rb).ok_or("Nothing to play.")?;
    let n1 = (d1.frames() as f64).max(1.0);
    let map_a = |f: f64| f * n / n1;
    let map_b = |f: f64| (f * n + delta as f64) / n1;
    let mut q = *g;
    if only_selection {
        q.start = map_a(ra);
        q.end = map_b(rb);
    } else {
        q.start = map_a(g.start);
        q.end = map_b(g.end);
    }
    Ok(process_selection(&d1, &q))
}

// ---- structural edits (frame indices)

pub fn silence(rate: u32, frames: usize) -> Decoded {
    Decoded { samples: vec![0.0; frames * 2], rate }
}

pub fn slice(d: &Decoded, a: usize, b: usize) -> Decoded {
    let n = d.frames();
    let (a, b) = (a.min(n), b.min(n));
    Decoded { samples: d.samples[a * 2..b.max(a) * 2].to_vec(), rate: d.rate }
}

pub fn delete_range(d: &Decoded, a: usize, b: usize) -> Decoded {
    let n = d.frames();
    let (a, b) = (a.min(n), b.min(n));
    let mut s = d.samples[..a * 2].to_vec();
    s.extend_from_slice(&d.samples[b.max(a) * 2..]);
    Decoded { samples: s, rate: d.rate }
}

/// `ins` must have the same sample rate as `d` (see `to_rate`).
pub fn insert_at(d: &Decoded, at: usize, ins: &Decoded) -> Decoded {
    let at = at.min(d.frames());
    let mut s = d.samples[..at * 2].to_vec();
    s.extend_from_slice(&ins.samples);
    s.extend_from_slice(&d.samples[at * 2..]);
    Decoded { samples: s, rate: d.rate }
}

pub fn to_rate(d: &Decoded, rate: u32) -> Decoded {
    if d.rate == rate || d.frames() < 2 {
        return Decoded { samples: d.samples.clone(), rate };
    }
    let x: Vec<Frame> = d.samples.as_chunks::<2>().0.iter().map(|c| [c[0], c[1]]).collect();
    let y = resample(&x, d.rate as f64 / rate as f64);
    Decoded { samples: y.into_iter().flatten().collect(), rate }
}

/// 16-bit stereo PCM WAV.
pub fn write_wav(path: &Path, d: &Decoded) -> Result<(), String> {
    let data_len = (d.samples.len() * 2) as u32;
    let mut buf: Vec<u8> = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
    buf.extend_from_slice(&2u16.to_le_bytes()); // stereo
    buf.extend_from_slice(&d.rate.to_le_bytes());
    buf.extend_from_slice(&(d.rate * 4).to_le_bytes());
    buf.extend_from_slice(&4u16.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for s in &d.samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        buf.extend_from_slice(&v.to_le_bytes());
    }
    // Write next to the target first, then move into place.
    let tmp = path.with_extension("wav.tmp");
    File::create(&tmp)
        .and_then(|mut f| f.write_all(&buf))
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Output formats the editor can write. WAV is built in; the rest use `ffmpeg`.
pub const FORMATS: [&str; 6] = ["wav", "mp3", "ogg", "flac", "opus", "m4a"];

/// Finds ffmpeg: `EASYBOARD_FFMPEG`, a copy shipped next to the executable, the PATH
/// (including .cmd/.bat shims on Windows), then a few well-known install folders.
pub fn ffmpeg_path() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    let names: &[&str] = if cfg!(windows) {
        &["ffmpeg.exe", "ffmpeg.cmd", "ffmpeg.bat"]
    } else {
        &["ffmpeg"]
    };
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("EASYBOARD_FFMPEG") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            dirs.push(d.to_path_buf());
            dirs.push(d.join("ffmpeg"));
            dirs.push(d.join("ffmpeg").join("bin"));
            dirs.push(d.join("bin"));
            // macOS app bundle: EasyBoard.app/Contents/MacOS/easyboard, ffmpeg in Contents/Resources
            if let Some(contents) = d.parent() {
                dirs.push(contents.join("Resources"));
                dirs.push(contents.join("Resources").join("bin"));
            }
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    #[cfg(windows)]
    {
        for v in ["LOCALAPPDATA", "USERPROFILE", "ProgramData", "ProgramFiles"] {
            if let Some(b) = std::env::var_os(v) {
                let b = PathBuf::from(b);
                dirs.push(b.join("Microsoft").join("WinGet").join("Links"));
                dirs.push(b.join("scoop").join("shims"));
                dirs.push(b.join("chocolatey").join("bin"));
                dirs.push(b.join("ffmpeg").join("bin"));
            }
        }
        dirs.push(PathBuf::from(r"C:\ffmpeg\bin"));
    }
    #[cfg(target_os = "macos")]
    {
        dirs.push(PathBuf::from("/opt/homebrew/bin"));
        dirs.push(PathBuf::from("/usr/local/bin"));
    }
    for d in dirs {
        for n in names {
            let c = d.join(n);
            if c.is_file() {
                return Some(c);
            }
        }
    }
    None
}

fn ffmpeg_command() -> Option<std::process::Command> {
    // Our own search first; otherwise let the OS resolve plain "ffmpeg" via PATH.
    #[allow(unused_mut)]
    let mut c = std::process::Command::new(ffmpeg_path().unwrap_or_else(|| "ffmpeg".into()));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    Some(c)
}

/// Runs `ffmpeg -version`; the error says what was tried.
pub fn ffmpeg_probe() -> Result<(), String> {
    let found = ffmpeg_path();
    let mut c = ffmpeg_command().ok_or("ffmpeg was not found")?;
    match c
        .arg("-version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
    {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("ffmpeg ({}) exited with {s}", found.map(|p| p.display().to_string()).unwrap_or_else(|| "from PATH".into()))),
        Err(e) => Err(format!(
            "could not run ffmpeg ({}): {e}",
            found.map(|p| p.display().to_string()).unwrap_or_else(|| "searched PATH".into())
        )),
    }
}

pub fn ffmpeg_available() -> bool {
    ffmpeg_probe().is_ok()
}

/// Writes `d` to `path`; the format follows the file extension.
pub fn write_audio(path: &Path, d: &Decoded) -> Result<(), String> {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("wav").to_ascii_lowercase();
    if ext == "wav" {
        return write_wav(path, d);
    }
    let codec: &[&str] = match ext.as_str() {
        "mp3" => &["-codec:a", "libmp3lame", "-q:a", "2"],
        "ogg" | "oga" => &["-codec:a", "libvorbis", "-q:a", "5"],
        "opus" => &["-codec:a", "libopus", "-b:a", "128k"],
        "flac" => &["-codec:a", "flac"],
        "m4a" | "aac" => &["-codec:a", "aac", "-b:a", "192k"],
        other => return Err(format!("cannot write .{other} files")),
    };
    if let Err(why) = ffmpeg_probe() {
        return Err(format!("saving as .{ext} needs ffmpeg: {why} (WAV works without it)"));
    }
    let tmp_wav = std::env::temp_dir().join(format!("easyboard-edit-{}.wav", std::process::id()));
    write_wav(&tmp_wav, d)?;
    let tmp_out = path.with_file_name(format!(
        "{}.easyboard-tmp.{ext}",
        path.file_stem().and_then(|s| s.to_str()).unwrap_or("sound")
    ));
    let Some(mut cmd) = ffmpeg_command() else {
        let _ = std::fs::remove_file(&tmp_wav);
        return Err("ffmpeg was not found".into());
    };
    let out = cmd
        .args(["-y", "-loglevel", "error", "-i"])
        .arg(&tmp_wav)
        .args(codec)
        .arg(&tmp_out)
        .output();
    let _ = std::fs::remove_file(&tmp_wav);
    let out = out.map_err(|e| format!("could not run ffmpeg: {e}"))?;
    if !out.status.success() {
        let _ = std::fs::remove_file(&tmp_out);
        return Err(format!("ffmpeg failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    std::fs::rename(&tmp_out, path).map_err(|e| format!("cannot write {}: {e}", path.display()))
}
