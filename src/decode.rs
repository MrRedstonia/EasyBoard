use std::{fs::File, path::Path};
use symphonia::core::{
    audio::SampleBuffer, codecs::DecoderOptions, errors::Error, formats::FormatOptions,
    io::MediaSourceStream, meta::MetadataOptions, probe::Hint,
};

/// A fully decoded clip: interleaved stereo f32 at the file's own sample rate.
pub struct Decoded {
    pub samples: Vec<f32>,
    pub rate: u32,
}

impl Decoded {
    pub fn frames(&self) -> usize {
        self.samples.len() / 2
    }
    pub fn bytes(&self) -> usize {
        self.samples.len() * 4
    }
}

/// Duration in seconds from the container header, without decoding. None if unknown.
pub fn probe_duration(path: &Path) -> Option<f64> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .ok()?;
    let track = probed
        .format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)?;
    let frames = track.codec_params.n_frames?;
    let rate = track.codec_params.sample_rate?;
    Some(frames as f64 / rate as f64)
}

pub fn decode_file(path: &Path) -> Result<Decoded, String> {
    let file = File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("unsupported or corrupt audio file: {e}"))?;
    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
        .ok_or("no audio track found")?;
    let track_id = track.id;
    let mut rate = track.codec_params.sample_rate.unwrap_or(44_100);

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("unsupported codec: {e}"))?;

    let mut out: Vec<f32> = Vec::new();
    let mut sbuf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(Error::ResetRequired) => break,
            Err(e) => return Err(e.to_string()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(buf) => {
                let spec = *buf.spec();
                rate = spec.rate;
                let channels = spec.channels.count().max(1);
                if sbuf.as_ref().is_none_or(|s| s.capacity() < buf.capacity()) {
                    sbuf = Some(SampleBuffer::<f32>::new(buf.capacity() as u64, spec));
                }
                let sb = sbuf.as_mut().unwrap();
                sb.copy_interleaved_ref(buf);
                for frame in sb.samples().chunks_exact(channels) {
                    match channels {
                        1 => {
                            out.push(frame[0]);
                            out.push(frame[0]);
                        }
                        _ => {
                            out.push(frame[0]);
                            out.push(frame[1]);
                        }
                    }
                }
            }
            Err(Error::DecodeError(_)) => continue, // skip a bad packet
            Err(e) => return Err(e.to_string()),
        }
    }

    if out.is_empty() {
        return Err("file contains no audio".into());
    }
    Ok(Decoded { samples: out, rate })
}
