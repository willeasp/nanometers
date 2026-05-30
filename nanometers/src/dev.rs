//! Dev-only file player. Decodes an audio file, plays it to the default output device, and
//! streams the same samples into the waveform ring — so you can watch a real song without
//! configuring a loopback device like BlackHole.
//!
//! Enabled with `--features dev-player` and the `NANO_DEV_FILE` env var:
//!
//! ```sh
//! NANO_DEV_FILE="/path/to/song.mp3" cargo run --features dev-player -- --backend dummy
//! ```
//!
//! Run against the `dummy` backend so nih-plug doesn't also grab an audio device — this thread
//! owns the output stream and the ring producer outright.

use std::path::{Path, PathBuf};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::StereoFrame;

/// Decode an entire audio file into interleaved stereo frames at its native sample rate. Mono
/// sources are duplicated to both channels.
fn decode(path: &Path) -> Result<(Vec<StereoFrame>, u32), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("open {path:?}: {e}"))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("probe: {e}"))?;
    let mut format = probed.format;

    let track = format.default_track().ok_or("no default track")?;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("make decoder: {e}"))?;

    let mut frames: Vec<StereoFrame> = Vec::new();
    let mut sample_rate = track.codec_params.sample_rate.unwrap_or(48_000);
    let mut sample_buf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            // The reader signals end-of-stream with an unexpected-EOF IoError; anything else we
            // also treat as "stop decoding" and just play what we have.
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(audio_buf) => {
                let spec = *audio_buf.spec();
                sample_rate = spec.rate;
                let channels = spec.channels.count();

                let sb = sample_buf
                    .get_or_insert_with(|| SampleBuffer::<f32>::new(audio_buf.capacity() as u64, spec));
                sb.copy_interleaved_ref(audio_buf);
                let samples = sb.samples();

                if channels >= 2 {
                    for f in samples.chunks_exact(channels) {
                        frames.push([f[0], f[1]]);
                    }
                } else {
                    for &s in samples {
                        frames.push([s, s]);
                    }
                }
            }
            // Decode errors on a single packet are recoverable — skip it.
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(_) => break,
        }
    }

    if frames.is_empty() {
        return Err("decoded zero frames".into());
    }
    Ok((frames, sample_rate))
}

/// Spawn the dev player: decode `path`, then drive the default output device, feeding the same
/// samples into the waveform ring via `producer`. The cpal callback is the realtime clock, so the
/// waveform stays in lockstep with what you hear. Loops forever.
pub fn spawn(path: PathBuf, mut producer: rtrb::Producer<StereoFrame>) {
    std::thread::spawn(move || {
        let (frames, file_rate) = match decode(&path) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[dev-player] decode failed: {e}");
                return;
            }
        };
        eprintln!(
            "[dev-player] decoded {} frames @ {file_rate} Hz from {path:?}",
            frames.len()
        );

        let host = cpal::default_host();
        let Some(device) = host.default_output_device() else {
            eprintln!("[dev-player] no default output device");
            return;
        };
        let device_name = device
            .description()
            .map(|d| d.name().to_string())
            .unwrap_or_else(|_| "<unknown>".into());
        eprintln!("[dev-player] output device: {device_name:?}");
        let config = match device.default_output_config() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[dev-player] default output config: {e}");
                return;
            }
        };

        let sample_format = config.sample_format();
        let stream_rate = config.sample_rate();
        let out_channels = config.channels() as usize;
        let stream_config = config.config();

        // Walk the decoded buffer at file_rate / stream_rate samples per output frame, linearly
        // interpolating. Handles any rate mismatch (e.g. a 48 kHz file on a 44.1 kHz device)
        // without a separate resampler.
        let step = file_rate as f64 / stream_rate as f64;
        let n = frames.len();
        let mut cursor = 0.0f64;

        if sample_format != cpal::SampleFormat::F32 {
            eprintln!("[dev-player] unsupported output sample format {sample_format:?} (want F32)");
            return;
        }

        let stream = device.build_output_stream(
            &stream_config,
            move |data: &mut [f32], _| {
                for frame in data.chunks_mut(out_channels) {
                    let i = cursor as usize;
                    let frac = (cursor - i as f64) as f32;
                    let a = frames[i % n];
                    let b = frames[(i + 1) % n];
                    let l = a[0] + (b[0] - a[0]) * frac;
                    let r = a[1] + (b[1] - a[1]) * frac;

                    if out_channels >= 2 {
                        frame[0] = l;
                        frame[1] = r;
                        for s in &mut frame[2..] {
                            *s = 0.0;
                        }
                    } else if let Some(s) = frame.first_mut() {
                        *s = 0.5 * (l + r);
                    }

                    // Feed the visualizer. If the GUI is starved and the ring is full we just drop
                    // the frame — playback must never block.
                    let _ = producer.push([l, r]);

                    cursor += step;
                    if cursor >= n as f64 {
                        cursor -= n as f64;
                    }
                }
            },
            |e| eprintln!("[dev-player] stream error: {e}"),
            None,
        );

        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[dev-player] build output stream: {e}");
                return;
            }
        };
        if let Err(e) = stream.play() {
            eprintln!("[dev-player] play: {e}");
            return;
        }
        eprintln!("[dev-player] playing @ {stream_rate} Hz, {out_channels} ch — looping");

        // Keep the stream (and thus playback) alive for the life of the process.
        std::thread::park();
    });
}
