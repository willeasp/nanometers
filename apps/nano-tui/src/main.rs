//! nanoplayer — THROWAWAY terminal mp3-player + meter prototype.
//!
//! QUESTION it answers: can the renderer live in the terminal — scrolling waveform + LUFS bars,
//! spectrally colored *like the plugin* — by reusing the plugin's DSP core instead of wgpu? And is
//! the audio→data seam clean enough that a non-GPU frontend is just "drain a ring → draw cells"?
//! If yes, this is the seed of a shared-DSP crate the monorepo idea rests on.
//!
//! What's reused from the plugin, verbatim (the thesis):
//!   * `nano_dsp::loudness::LoudnessDsp` — momentary/short/integrated LUFS.
//!   * `nano_dsp::waveform::color::{Filterbank, band_color}` — the spectral coloring
//!     (low→red, mid→green, high→blue; dominance drives saturation), same crossovers + white-mix.
//! Both are fed frame-by-frame off the same `rtrb` ring the wgpu GUI drains.
//!
//! What's a throwaway shell: the cpal engine, symphonia decode, cover-art half-block render, and
//! the crossterm TUI below. A real shared crate would unify decode+playback (today dup'd `dev.rs`).
//!
//! Run:  cargo run --features nanoplayer --bin nanoplayer -- /path/to/song.mp3
//!       (falls back to NANO_DEV_FILE; auto-builds a playlist from the file's folder)
//!
//! Keys: [space] play/pause · [←/→] seek ±5s (Shift ±30s) · [n/p] or [↑/↓] track · [q] quit

use std::collections::VecDeque;
use std::fmt::Write as _;
use std::io::{Write, stdout};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    terminal::{self, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, MetadataRevision, StandardTagKey, StandardVisualKey};
use symphonia::core::probe::{Hint, ProbeResult, ProbedMetadata};

use nano_dsp::StereoFrame;
use nano_dsp::loudness::{Channels, LoudnessDsp};
use nano_dsp::waveform::color::{Filterbank, band_color};

/// Seconds of audio shown across the full waveform width (the scroll window).
const WINDOW_SECS: f32 = 4.0;
/// Visualizer ring capacity (stereo pairs). Matches the plugin's audio→GUI ring.
const RING_CAPACITY: usize = 32_768;
/// Render cadence. Terminal scroll is cell-quantized, so there's no point chasing vsync here.
const TARGET_FPS: u64 = 60;
/// Peak-meter fall time: 12 dB in this many ms after silence (mirrors the plugin's ballistics).
const PEAK_DECAY_MS: f64 = 250.0;
/// Spectral-color crossovers + white-mix, mirrored from `module/waveform/mod.rs` so the terminal
/// waveform matches the plugin's palette.
const BAND_LOW_HZ: f32 = 250.0;
const BAND_HIGH_HZ: f32 = 4000.0;
const COLOR_WHITE_MIX: f32 = 0.18;
/// Seek granularity for the arrow keys (Shift = the big jump).
const SEEK_SECS: f64 = 5.0;
const SEEK_SECS_BIG: f64 = 30.0;
/// Audio extensions we'll enumerate as sibling tracks in a folder.
const AUDIO_EXTS: [&str; 6] = ["mp3", "flac", "wav", "aac", "m4a", "ogg"];

// --- ANSI SGR helpers (no styling crate; terminals speak these directly) -------------------------
const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const GREEN: &str = "\x1b[38;5;42m";
const YELLOW: &str = "\x1b[38;5;220m";
const RED: &str = "\x1b[38;5;203m";
const GREY: &str = "\x1b[38;5;240m";
const UPPER_HALF: char = '\u{2580}'; // ▀ — fg = top pixel, bg = bottom pixel

/// True when the terminal advertises 24-bit color (ghostty sets `COLORTERM=truecolor`). Drives
/// whether the waveform + cover use truecolor SGR or fall back to the 256-color cube.
fn detect_truecolor() -> bool {
    std::env::var("COLORTERM")
        .map(|v| v.eq_ignore_ascii_case("truecolor") || v.eq_ignore_ascii_case("24bit"))
        .unwrap_or(false)
}

/// Detect whether the terminal background is *light* — so the waveform palette can darken to stay
/// visible instead of washing out. Order: explicit `NANO_THEME=light|dark`, then the actual
/// terminal background via an OSC 11 query (works regardless of the OS theme), then the macOS
/// system appearance, then assume dark.
fn detect_bg_is_light() -> bool {
    if let Ok(v) = std::env::var("NANO_THEME") {
        if v.eq_ignore_ascii_case("light") {
            return true;
        }
        if v.eq_ignore_ascii_case("dark") {
            return false;
        }
    }
    if let Some(lum) = query_terminal_bg_luminance() {
        return lum > 0.5;
    }
    match macos_appearance_is_dark() {
        Some(dark) => !dark,
        None => false, // unknown → assume dark (the original behavior)
    }
}

/// Ask the terminal for its background color (OSC 11) and return its perceived luminance in [0,1].
/// Reads the reply straight off the tty with a `poll(2)` deadline so terminals that don't answer
/// (or piped output) just time out instead of hanging. Raw mode must already be on.
fn query_terminal_bg_luminance() -> Option<f32> {
    use std::os::unix::io::AsRawFd;
    let fd = std::io::stdin().as_raw_fd();
    if unsafe { libc::isatty(fd) } != 1 {
        return None;
    }

    let mut out = stdout();
    out.write_all(b"\x1b]11;?\x07").ok()?;
    out.flush().ok()?;

    let deadline = Instant::now() + Duration::from_millis(150);
    let mut buf: Vec<u8> = Vec::with_capacity(64);
    let mut tmp = [0u8; 64];
    loop {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let ms = (deadline - now).as_millis() as i32;
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut pfd as *mut _, 1, ms) } <= 0 {
            break; // timeout or error
        }
        let n = unsafe { libc::read(fd, tmp.as_mut_ptr() as *mut libc::c_void, tmp.len()) };
        if n <= 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n as usize]);
        // Stop at the OSC terminator: BEL (0x07) or ST (ESC \).
        if buf.contains(&0x07) || buf.windows(2).any(|w| w == [0x1b, b'\\']) || buf.len() > 256 {
            break;
        }
    }
    parse_osc11_luminance(&String::from_utf8_lossy(&buf))
}

/// Parse an OSC 11 reply like `\x1b]11;rgb:rrrr/gggg/bbbb\x07` into Rec.601 luminance in [0,1].
fn parse_osc11_luminance(s: &str) -> Option<f32> {
    let rest = &s[s.find("rgb:")? + 4..];
    let comp = |c: &str| -> Option<f32> {
        let hex: String = c.chars().take_while(|ch| ch.is_ascii_hexdigit()).collect();
        if hex.is_empty() {
            return None;
        }
        let v = u32::from_str_radix(&hex, 16).ok()?;
        let max = ((1u64 << (4 * hex.len())) - 1) as f32;
        Some(v as f32 / max)
    };
    let mut it = rest.split('/');
    let r = comp(it.next()?)?;
    let g = comp(it.next()?)?;
    let b = comp(it.next()?)?;
    Some(0.299 * r + 0.587 * g + 0.114 * b)
}

/// macOS system appearance: `defaults read -g AppleInterfaceStyle` prints "Dark" in dark mode and
/// errors (empty) in light mode. None if `defaults` can't run (non-macOS).
fn macos_appearance_is_dark() -> Option<bool> {
    let out = std::process::Command::new("defaults")
        .args(["read", "-g", "AppleInterfaceStyle"])
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_lowercase().contains("dark"))
}

/// Tone-map a spectral color for the background. On a dark bg, lift gently toward white (as the
/// plugin does). On a light bg, darken: keep the hue but pull broadband/white content down to a
/// dark grey so the waveform stays visible.
fn tone(c: [f32; 3], bg_light: bool) -> [f32; 3] {
    if !bg_light {
        [
            c[0] + (1.0 - c[0]) * COLOR_WHITE_MIX,
            c[1] + (1.0 - c[1]) * COLOR_WHITE_MIX,
            c[2] + (1.0 - c[2]) * COLOR_WHITE_MIX,
        ]
    } else {
        let mx = c[0].max(c[1]).max(c[2]).max(1e-6);
        let mn = c[0].min(c[1]).min(c[2]); // ~0 for a pure hue, ~1 for white/broadband
        let v = 0.6 * (1.0 - 0.75 * mn); // pure hue → 0.6, broadband → ~0.15 (dark grey)
        [c[0] / mx * v, c[1] / mx * v, c[2] / mx * v]
    }
}

/// Nearest xterm-256 cube axis (0..=5) for an 8-bit channel; cube ramp is {0,95,135,175,215,255}.
fn cube_axis(c: u8) -> u8 {
    const STEPS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let mut best = 0u8;
    let mut best_d = u16::MAX;
    for (level, &s) in STEPS.iter().enumerate() {
        let d = (c as i16 - s as i16).unsigned_abs();
        if d < best_d {
            best_d = d;
            best = level as u8;
        }
    }
    best
}

/// xterm-256 palette index for an RGB triple via the 6×6×6 cube (16 + 36r + 6g + b).
fn cube_index(r: u8, g: u8, b: u8) -> u8 {
    16 + 36 * cube_axis(r) + 6 * cube_axis(g) + cube_axis(b)
}

/// Append a foreground (`is_fg`) or background SGR for `(r,g,b)`: truecolor when available, else
/// the 256-color cube. Writing to a `String` is infallible.
fn push_color(out: &mut String, r: u8, g: u8, b: u8, is_fg: bool, truecolor: bool) {
    let layer = if is_fg { 38 } else { 48 };
    if truecolor {
        let _ = write!(out, "\x1b[{layer};2;{r};{g};{b}m");
    } else {
        let _ = write!(out, "\x1b[{layer};5;{}m", cube_index(r, g, b));
    }
}

// ================================================================================================
// WaveScope — rolling window of recent samples, rendered as a spectrally-colored braille envelope.
// Reuses the plugin's Filterbank + band_color (fed continuously); kept free of I/O so it could be
// lifted into a shared viz crate. The plugin half (LoudnessDsp) is already portable; this is the
// waveform half.
// ================================================================================================

/// One windowed sample: the mono amplitude (for the envelope) and the squared 3-band powers
/// (low/mid/high) that drive its column color — same data the plugin's `band_ms` accumulates.
#[derive(Clone, Copy)]
struct ScopeSample {
    mono: f32,
    band_power: [f32; 3],
}

struct WaveScope {
    samples: VecDeque<ScopeSample>,
    capacity: usize,
}

impl WaveScope {
    fn new(sample_rate: u32) -> Self {
        let capacity = ((sample_rate as f32 * WINDOW_SECS).round() as usize).max(1);
        Self {
            samples: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    fn push(&mut self, mono: f32, band_power: [f32; 3]) {
        if self.samples.len() == self.capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(ScopeSample { mono, band_power });
    }

    /// Render the window into `rows` braille lines (cells = 2×4 dots), oldest→newest L→R. Each
    /// terminal column is colored by its mean band power via the plugin's `band_color`.
    fn render(&self, cols: usize, rows: usize, truecolor: bool, bg_light: bool) -> Vec<String> {
        // `terminal::size()` can report 0 columns mid-resize; bail before the grid math indexes it.
        if cols == 0 || rows == 0 {
            return vec![String::new(); rows];
        }
        let dot_w = (cols * 2).max(1);
        let dot_h = (rows * 4).max(4);
        let mut grid = vec![0u8; rows * cols];
        let default = if bg_light { [150u8, 150, 150] } else { [40, 40, 40] };
        let mut colors = vec![default; cols];
        let len = self.samples.len();

        if len > 0 {
            let (a, b) = self.samples.as_slices();
            let at = |i: usize| if i < a.len() { a[i] } else { b[i - a.len()] };
            let center = dot_h as f32 / 2.0;

            // Envelope: per dot-column, the min/max mono amplitude → filled vertical span.
            for x in 0..dot_w {
                let lo = x * len / dot_w;
                let hi = ((x + 1) * len / dot_w).max(lo + 1).min(len);
                let mut mn = f32::INFINITY;
                let mut mx = f32::NEG_INFINITY;
                for i in lo..hi {
                    let v = at(i).mono;
                    mn = mn.min(v);
                    mx = mx.max(v);
                }
                let to_row = |amp: f32| (center - amp.clamp(-1.0, 1.0) * center).round() as i32;
                let mut y0 = to_row(mx);
                let mut y1 = to_row(mn);
                if y0 > y1 {
                    std::mem::swap(&mut y0, &mut y1);
                }
                let y0 = y0.clamp(0, dot_h as i32 - 1);
                let y1 = y1.clamp(0, dot_h as i32 - 1);
                for y in y0..=y1 {
                    let (y, x) = (y as usize, x);
                    grid[(y / 4) * cols + (x / 2)] |= braille_bit(x % 2, y % 4);
                }
            }

            // Color: per terminal column, the mean band power → band_color → white-mix (plugin parity).
            for (c, slot) in colors.iter_mut().enumerate() {
                let lo = c * len / cols;
                let hi = ((c + 1) * len / cols).max(lo + 1).min(len);
                let mut acc = [0.0f32; 3];
                for i in lo..hi {
                    let bp = at(i).band_power;
                    acc[0] += bp[0];
                    acc[1] += bp[1];
                    acc[2] += bp[2];
                }
                let inv = 1.0 / (hi - lo) as f32;
                let rgb = tone(band_color([acc[0] * inv, acc[1] * inv, acc[2] * inv]), bg_light);
                *slot = [to_u8(rgb[0]), to_u8(rgb[1]), to_u8(rgb[2])];
            }
        }

        let mut lines = Vec::with_capacity(rows);
        for r in 0..rows {
            let mut line = String::with_capacity(cols * 8);
            let mut active = false;
            for c in 0..cols {
                let mask = grid[r * cols + c];
                if mask == 0 {
                    if active {
                        line.push_str(RESET);
                        active = false;
                    }
                    line.push(' ');
                } else {
                    let [cr, cg, cb] = colors[c];
                    push_color(&mut line, cr, cg, cb, true, truecolor);
                    line.push(char::from_u32(0x2800 + mask as u32).unwrap_or(' '));
                    active = true;
                }
            }
            if active {
                line.push_str(RESET);
            }
            lines.push(line);
        }
        lines
    }
}

fn to_u8(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// Braille dot bitmask for a sub-cell coordinate (col 0..2, row 0..4). U+2800 + mask = glyph.
fn braille_bit(col: usize, row: usize) -> u8 {
    match (col, row) {
        (0, 0) => 0x01,
        (0, 1) => 0x02,
        (0, 2) => 0x04,
        (0, 3) => 0x40,
        (1, 0) => 0x08,
        (1, 1) => 0x10,
        (1, 2) => 0x20,
        (1, 3) => 0x80,
        _ => 0,
    }
}

// ================================================================================================
// Cover art — decode embedded JPEG/PNG to RGB8, render as truecolor upper-half-blocks (2 px/cell).
// ================================================================================================

/// One decoded cover: tightly-packed RGB8, row-major (`3 * w * h` bytes).
struct Rgb8Image {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl Rgb8Image {
    fn decode(bytes: &[u8]) -> Option<Self> {
        let rgb = image::load_from_memory(bytes).ok()?.to_rgb8();
        let (width, height) = (rgb.width(), rgb.height());
        Some(Self {
            width,
            height,
            pixels: rgb.into_raw(),
        })
    }

    fn pixel(&self, x: u32, y: u32) -> [u8; 3] {
        let i = ((y * self.width + x) * 3) as usize;
        [self.pixels[i], self.pixels[i + 1], self.pixels[i + 2]]
    }

    /// Render into `cols × rows` cells of half-block art, one `String` per row. A cell splits into
    /// 2 stacked square pixels (fg = top, bg = bottom), so the pixel grid is `cols × rows*2` square
    /// pixels — a square cover wants `cols ≈ rows*2`. Aspect-preserving, letterboxed + centered.
    fn render_half_blocks(&self, cols: usize, rows: usize, truecolor: bool) -> Vec<String> {
        let cols = cols.max(1) as u32;
        let rows = rows.max(1) as u32;
        let budget_w = cols;
        let budget_h = rows * 2;
        if self.width == 0 || self.height == 0 {
            return vec![String::new(); rows as usize];
        }

        // Largest aspect-preserving grid inside the square-pixel budget (integer cross-multiply).
        let (sw, sh) = (self.width as u64, self.height as u64);
        let (grid_w, grid_h) = if sw * budget_h as u64 >= sh * budget_w as u64 {
            let w = budget_w;
            let h = ((w as u64 * sh) / sw).max(1) as u32;
            (w, h.min(budget_h))
        } else {
            let h = budget_h;
            let w = ((h as u64 * sw) / sh).max(1) as u32;
            (w.min(budget_w), h)
        };
        let off_x = (budget_w - grid_w) / 2;
        let off_top = (budget_h - grid_h) / 2;

        let sample = |gx: u32, gy: u32| -> [u8; 3] {
            let sx = (gx as u64 * sw / grid_w as u64).min(sw - 1) as u32;
            let sy = (gy as u64 * sh / grid_h as u64).min(sh - 1) as u32;
            self.pixel(sx, sy)
        };

        let mut out = Vec::with_capacity(rows as usize);
        for row in 0..rows {
            let (top_py, bot_py) = (row * 2, row * 2 + 1);
            let mut line = String::new();
            let mut active = false;
            for cell in 0..cols {
                let in_x = cell >= off_x && cell < off_x + grid_w;
                let top_in = in_x && top_py >= off_top && top_py < off_top + grid_h;
                let bot_in = in_x && bot_py >= off_top && bot_py < off_top + grid_h;
                if !top_in && !bot_in {
                    if active {
                        line.push_str(RESET);
                        active = false;
                    }
                    line.push(' ');
                } else {
                    let gx = cell - off_x;
                    let top = if top_in { sample(gx, top_py - off_top) } else { [0, 0, 0] };
                    let bot = if bot_in { sample(gx, bot_py - off_top) } else { [0, 0, 0] };
                    push_color(&mut line, top[0], top[1], top[2], true, truecolor);
                    push_color(&mut line, bot[0], bot[1], bot[2], false, truecolor);
                    line.push(UPPER_HALF);
                    active = true;
                }
            }
            if active {
                line.push_str(RESET);
            }
            out.push(line);
        }
        out
    }
}

// ================================================================================================
// Metadata — title/artist/album/etc + embedded cover art, read from BOTH the probe-time metadata
// (where mp3/AAC ID3v2 lands) and the container metadata (FLAC/MP4/WAV). Verified against the
// symphonia 0.5.5 source.
// ================================================================================================

#[derive(Default, Clone)]
struct Tags {
    title: Option<String>,
    artist: Option<String>,
    album_artist: Option<String>,
    album: Option<String>,
    track_number: Option<String>,
    date: Option<String>,
}

impl Tags {
    fn merge_revision(&mut self, rev: &MetadataRevision) {
        for tag in rev.tags() {
            let Some(std_key) = tag.std_key else { continue };
            let value = tag.value.to_string();
            if value.is_empty() {
                continue;
            }
            match std_key {
                StandardTagKey::TrackTitle => self.title = Some(value),
                StandardTagKey::Artist => self.artist = Some(value),
                StandardTagKey::AlbumArtist => self.album_artist = Some(value),
                StandardTagKey::Album => self.album = Some(value),
                StandardTagKey::TrackNumber => self.track_number = Some(value),
                StandardTagKey::Date => self.date = Some(value),
                _ => {}
            }
        }
    }
}

/// First usable embedded cover image bytes (prefer an explicit front cover, else the first visual).
fn cover_from_revision(rev: &MetadataRevision) -> Option<Vec<u8>> {
    let visuals = rev.visuals();
    let pick = visuals
        .iter()
        .find(|v| v.usage == Some(StandardVisualKey::FrontCover))
        .or_else(|| visuals.first())?;
    Some(pick.data.to_vec())
}

/// Read tags + cover from both metadata sources (mp3 ID3 surfaces in `probed_meta`, container tags
/// in `format.metadata()`); container values layer on top where present.
fn read_tags_and_cover(
    probed_meta: &mut ProbedMetadata,
    format: &mut dyn FormatReader,
) -> (Tags, Option<Vec<u8>>) {
    let mut tags = Tags::default();
    let mut cover = None;

    if let Some(md) = probed_meta.get() {
        if let Some(rev) = md.current() {
            tags.merge_revision(rev);
            cover = cover_from_revision(rev);
        }
    }
    {
        let mut md = format.metadata();
        if let Some(rev) = md.skip_to_latest() {
            tags.merge_revision(rev);
            if cover.is_none() {
                cover = cover_from_revision(rev);
            }
        }
    }
    (tags, cover)
}

// ================================================================================================
// Decode — whole file → interleaved stereo frames + native rate + tags + decoded cover.
// ================================================================================================

struct Decoded {
    frames: Vec<StereoFrame>,
    sample_rate: u32,
    is_mono: bool,
    tags: Tags,
    cover: Option<Rgb8Image>,
}

fn decode(path: &Path) -> Result<Decoded, String> {
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
    let ProbeResult {
        mut format,
        mut metadata,
    } = probed;

    // Read metadata up front, before the decode loop consumes packets.
    let (tags, cover_bytes) = read_tags_and_cover(&mut metadata, format.as_mut());

    let track = format.default_track().ok_or("no default track")?;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("make decoder: {e}"))?;

    let mut frames: Vec<StereoFrame> = Vec::new();
    let mut sample_rate = track.codec_params.sample_rate.unwrap_or(48_000);
    let mut sample_buf: Option<SampleBuffer<f32>> = None;
    let mut src_channels = 2usize;

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
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
                src_channels = channels;

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
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(_) => break,
        }
    }

    if frames.is_empty() {
        return Err("decoded zero frames".into());
    }

    let cover = cover_bytes.and_then(|b| Rgb8Image::decode(&b));
    Ok(Decoded {
        frames,
        sample_rate,
        is_mono: src_channels < 2,
        tags,
        cover,
    })
}

// ================================================================================================
// Playback engine — cpal output stream + the atomics-only transport seam (paused / seek / ended /
// cursor) read by the RT callback. The callback never allocates, locks, or blocks.
// ================================================================================================

struct Control {
    /// Playback position in source-frame units (for the time readout). Callback writes.
    cursor: AtomicUsize,
    paused: AtomicBool,
    /// Pending seek target (source frame), or -1 for none. TUI sets, callback consumes via swap.
    seek_to_frame: AtomicI64,
    /// Set by the callback at EOF; TUI polls it to auto-advance. Sticky until the next track.
    ended: AtomicBool,
}

impl Control {
    fn new() -> Self {
        Self {
            cursor: AtomicUsize::new(0),
            paused: AtomicBool::new(false),
            seek_to_frame: AtomicI64::new(-1),
            ended: AtomicBool::new(false),
        }
    }

    fn request_seek(&self, frame: usize) {
        self.seek_to_frame.store(frame as i64, Ordering::Relaxed);
        self.ended.store(false, Ordering::Relaxed);
    }
}

fn start_playback(
    frames: Arc<Vec<StereoFrame>>,
    file_rate: u32,
    mut producer: rtrb::Producer<StereoFrame>,
    control: Arc<Control>,
) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("no default output device")?;
    let config = device
        .default_output_config()
        .map_err(|e| format!("default output config: {e}"))?;

    if config.sample_format() != cpal::SampleFormat::F32 {
        return Err(format!(
            "unsupported output sample format {:?} (want F32)",
            config.sample_format()
        ));
    }

    let stream_rate = config.sample_rate();
    let out_channels = config.channels() as usize;
    let stream_config = config.config();

    let step = file_rate as f64 / stream_rate as f64;
    let n = frames.len();
    let mut play_cursor = 0.0f64;

    let stream = device
        .build_output_stream(
            &stream_config,
            move |data: &mut [f32], _| {
                // Apply a pending seek once per buffer (single atomic RMW; RT-safe).
                let req = control.seek_to_frame.swap(-1, Ordering::Relaxed);
                if req >= 0 {
                    play_cursor = (req as f64).clamp(0.0, n.saturating_sub(1) as f64);
                    control.ended.store(false, Ordering::Relaxed);
                    // Publish the new position now, so the readout stays truthful even while paused
                    // (the per-frame store below is skipped on the paused/EOF `continue`).
                    control.cursor.store(play_cursor as usize, Ordering::Relaxed);
                }
                let paused = control.paused.load(Ordering::Relaxed);

                for frame in data.chunks_mut(out_channels) {
                    // EOF or paused → silence. At EOF mark `ended` (sticky) so the TUI advances.
                    if paused || play_cursor >= n as f64 {
                        if !paused {
                            control.ended.store(true, Ordering::Relaxed);
                        }
                        for s in frame.iter_mut() {
                            *s = 0.0;
                        }
                        continue;
                    }

                    let i = play_cursor as usize;
                    let frac = (play_cursor - i as f64) as f32;
                    let a = frames[i];
                    let b = if i + 1 < n { frames[i + 1] } else { a };
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

                    let _ = producer.push([l, r]);

                    play_cursor += step;
                    control.cursor.store(play_cursor as usize, Ordering::Relaxed);
                }
            },
            |e| eprintln!("[nanoplayer] stream error: {e}"),
            None,
        )
        .map_err(|e| format!("build output stream: {e}"))?;
    stream.play().map_err(|e| format!("play: {e}"))?;
    Ok(stream)
}

// ================================================================================================
// Playlist — sibling audio files in the folder, natural-sorted (track2 before track10).
// ================================================================================================

fn is_audio_file(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| AUDIO_EXTS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

fn file_name_str(p: &Path) -> &str {
    p.file_name().and_then(|n| n.to_str()).unwrap_or("")
}

fn list_sibling_tracks(path: &Path) -> Vec<PathBuf> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tracks: Vec<PathBuf> = match std::fs::read_dir(dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file() && is_audio_file(p))
            .collect(),
        Err(_) => return vec![path.to_path_buf()],
    };
    if tracks.is_empty() {
        return vec![path.to_path_buf()];
    }
    tracks.sort_by(|a, b| natural_cmp(file_name_str(a), file_name_str(b)));
    tracks
}

fn index_of(playlist: &[PathBuf], path: &Path) -> usize {
    let target = std::fs::canonicalize(path).ok();
    playlist
        .iter()
        .position(|p| match (&target, std::fs::canonicalize(p).ok()) {
            (Some(t), Some(c)) => *t == c,
            _ => p.file_name() == path.file_name(),
        })
        .unwrap_or(0)
}

/// Natural-order compare: digit runs compare by numeric value, other runs case-insensitively.
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut ai, mut bi) = (a.bytes().peekable(), b.bytes().peekable());
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(ca), Some(cb)) => {
                if ca.is_ascii_digit() && cb.is_ascii_digit() {
                    let da = take_digits(&mut ai);
                    let db = take_digits(&mut bi);
                    let (na, nb) = (da.trim_start_matches('0'), db.trim_start_matches('0'));
                    match na.len().cmp(&nb.len()).then_with(|| na.cmp(nb)) {
                        Ordering::Equal => match da.len().cmp(&db.len()) {
                            Ordering::Equal => continue,
                            ord => return ord,
                        },
                        ord => return ord,
                    }
                } else {
                    let (la, lb) = (ca.to_ascii_lowercase(), cb.to_ascii_lowercase());
                    if la != lb {
                        return la.cmp(&lb);
                    }
                    ai.next();
                    bi.next();
                }
            }
        }
    }
}

fn take_digits<I: Iterator<Item = u8>>(it: &mut std::iter::Peekable<I>) -> String {
    let mut s = String::new();
    while let Some(&c) = it.peek() {
        if c.is_ascii_digit() {
            s.push(c as char);
            it.next();
        } else {
            break;
        }
    }
    s
}

// ================================================================================================
// TUI — full-frame redraw each tick. Cover + metadata on top, colored waveform in the middle,
// LUFS/peak bars + help at the bottom.
// ================================================================================================

/// Restores the terminal on drop, even on panic.
struct TermGuard;
impl TermGuard {
    fn enter() -> std::io::Result<Self> {
        terminal::enable_raw_mode()?;
        crossterm::execute!(stdout(), EnterAlternateScreen, cursor::Hide)?;
        Ok(Self)
    }
}
impl Drop for TermGuard {
    fn drop(&mut self) {
        let _ = crossterm::execute!(stdout(), cursor::Show, LeaveAlternateScreen);
        let _ = terminal::disable_raw_mode();
    }
}

/// Everything the renderer needs for one frame.
struct View<'a> {
    name: &'a str,
    tags: &'a Tags,
    cover: Option<&'a Rgb8Image>,
    scope: &'a WaveScope,
    momentary: f64,
    short: f64,
    integrated: f64,
    peak_l: f32,
    peak_r: f32,
    pos_secs: f64,
    total_secs: f64,
    paused: bool,
    track_idx: usize,
    track_count: usize,
    truecolor: bool,
    bg_light: bool,
}

fn meter_bar(label: &str, value: f64, lo: f64, hi: f64, width: usize, zones: (f64, f64)) -> String {
    let frac = if value.is_finite() {
        ((value - lo) / (hi - lo)).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let fill = (frac * width as f64).round() as usize;
    let color = if !value.is_finite() || value <= zones.0 {
        GREEN
    } else if value <= zones.1 {
        YELLOW
    } else {
        RED
    };
    let num = if value.is_finite() {
        format!("{value:6.1}")
    } else {
        "  -inf".to_string()
    };
    let filled = "█".repeat(fill);
    let empty = "░".repeat(width - fill);
    format!("{BOLD}{label:<4}{RESET}{num}  {color}{filled}{GREY}{empty}{RESET}")
}

fn fmt_time(secs: f64) -> String {
    let secs = secs.max(0.0) as u64;
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

/// The text block shown beside the cover: title / artist / album / status+time / progress.
fn build_meta_lines(v: &View, width: usize) -> Vec<String> {
    let width = width.max(8);
    let title = v.tags.title.clone().unwrap_or_else(|| v.name.to_string());
    let artist = v
        .tags
        .artist
        .clone()
        .or_else(|| v.tags.album_artist.clone())
        .unwrap_or_else(|| "—".to_string());
    let mut album = v.tags.album.clone().unwrap_or_default();
    if let Some(date) = &v.tags.date {
        let year = date.get(0..4).unwrap_or(date.as_str());
        if !album.is_empty() {
            album = format!("{album} ({year})");
        } else {
            album = format!("({year})");
        }
    }

    let status = if v.paused {
        format!("{YELLOW}❙❙ paused{RESET}")
    } else {
        format!("{GREEN}▸ playing{RESET}")
    };
    let track = format!("{DIM}[{}/{}]{RESET}", v.track_idx + 1, v.track_count);
    let time = format!(
        "{DIM}{} / {}{RESET}",
        fmt_time(v.pos_secs),
        fmt_time(v.total_secs)
    );

    // Progress bar across the right column.
    let bar_w = width.clamp(8, 60);
    let frac = if v.total_secs > 0.0 {
        (v.pos_secs / v.total_secs).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let fill = (frac * bar_w as f64).round() as usize;
    let progress = format!(
        "\x1b[38;5;44m{}{GREY}{}{RESET}",
        "█".repeat(fill),
        "░".repeat(bar_w - fill)
    );

    vec![
        format!("{BOLD}{}{RESET}", truncate(&title, width)),
        format!("{DIM}{}{RESET}", truncate(&artist, width)),
        format!("{DIM}{}{RESET}", truncate(&album, width)),
        String::new(),
        format!("{status}  {time}  {track}"),
        progress,
    ]
}

/// Truncate a (plain, no-ANSI) string to `max` display chars, adding an ellipsis if cut.
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let keep = max.saturating_sub(1);
        format!("{}…", s.chars().take(keep).collect::<String>())
    }
}

fn render_frame(v: &View, cols: u16, rows: u16) -> String {
    let w = cols as usize;
    let h = rows as usize;
    let mut lines: Vec<String> = Vec::with_capacity(h);

    // --- top block: cover (left) + metadata (right) ---
    // Show the cover only if there's horizontal room for it AND the metadata; otherwise fall back
    // to a text-only header so a narrow window degrades gracefully instead of overflowing.
    let cover_rows = (h / 3).clamp(6, 12);
    let cover_cols = cover_rows * 2; // square cover
    let cover = v.cover.filter(|_| w >= cover_cols + 16);
    let meta_width = if cover.is_some() {
        w.saturating_sub(cover_cols + 2)
    } else {
        w
    };
    let meta = build_meta_lines(v, meta_width);

    let top_rows = if cover.is_some() { cover_rows } else { meta.len() };

    if let Some(img) = cover {
        let cover_lines = img.render_half_blocks(cover_cols, cover_rows, v.truecolor);
        let blank = " ".repeat(cover_cols);
        for r in 0..top_rows {
            let left = cover_lines.get(r).map(String::as_str).unwrap_or(&blank);
            let right = meta.get(r).cloned().unwrap_or_default();
            lines.push(format!("{left}  {right}"));
        }
    } else {
        for r in 0..top_rows {
            lines.push(meta.get(r).cloned().unwrap_or_default());
        }
    }

    lines.push(String::new());

    // --- waveform (fills the middle) ---
    let bottom = 5; // M/S/I (3) + peak (1) + help (1)
    let wave_rows = h.saturating_sub(top_rows + 1 + 1 + bottom).max(3);
    lines.extend(v.scope.render(w, wave_rows, v.truecolor, v.bg_light));
    lines.push(String::new());

    // --- meters ---
    let bar_w = w.saturating_sub(14).clamp(8, 48);
    lines.push(meter_bar("M", v.momentary, -36.0, 0.0, bar_w, (-18.0, -9.0)));
    lines.push(meter_bar("S", v.short, -36.0, 0.0, bar_w, (-18.0, -9.0)));
    lines.push(meter_bar("I", v.integrated, -36.0, 0.0, bar_w, (-18.0, -9.0)));

    let db = |p: f32| if p > 1e-9 { 20.0 * (p as f64).log10() } else { f64::NEG_INFINITY };
    let pk_w = (bar_w / 2).max(6);
    let pl = meter_bar("PkL", db(v.peak_l), -60.0, 0.0, pk_w, (-12.0, -3.0));
    let pr = meter_bar("PkR", db(v.peak_r), -60.0, 0.0, pk_w, (-12.0, -3.0));
    lines.push(format!("{pl}   {pr}"));

    lines.push(format!(
        "{DIM}[space]{RESET} play/pause  {DIM}[←/→]{RESET} seek  {DIM}[n/p]{RESET} track  {DIM}[f]{RESET} finder  {DIM}[t]{RESET} theme  {DIM}[q]{RESET} quit"
    ));

    // Assemble: home, overwrite each line (clear-to-EOL), clear below. No trailing newline after
    // the last line — emitting one on a full-height frame scrolls the alternate screen by a row.
    let visible: Vec<&String> = lines.iter().take(h).collect();
    let mut buf = String::from("\x1b[H");
    for (i, line) in visible.iter().enumerate() {
        buf.push_str(line);
        buf.push_str("\x1b[K");
        if i + 1 < visible.len() {
            buf.push_str("\r\n");
        }
    }
    buf.push_str("\x1b[J");
    buf
}

// ================================================================================================

fn resolve_path() -> Option<PathBuf> {
    std::env::args()
        .nth(1)
        .or_else(|| std::env::var("NANO_DEV_FILE").ok())
        .map(PathBuf::from)
}

/// Why the inner loop returned.
enum Transition {
    Quit,
    Next,
    Prev,
    Ended,
}

/// What a keypress means to the inner loop.
enum KeyOutcome {
    /// Pause toggle or unhandled key — keep going.
    None,
    /// Break the inner loop with this transition (quit / next / prev).
    Break(Transition),
    /// A seek was requested to this source frame — the GUI should jump the waveform to match.
    Seek(usize),
    /// Reveal the current file in Finder.
    Reveal,
    /// Flip the light/dark palette (manual override when auto-detect guesses wrong).
    ToggleTheme,
}

/// Handle one key. Seek requests are sent to the audio thread here and also reported back so the
/// GUI can rebuild its waveform window (which is otherwise a live history that lags a seek).
fn handle_key(key: KeyEvent, control: &Control, n_frames: usize, file_rate: u32) -> KeyOutcome {
    let big = key.modifiers.contains(KeyModifiers::SHIFT);
    let seek_secs = if big { SEEK_SECS_BIG } else { SEEK_SECS };
    let seek_frames = (seek_secs * file_rate as f64) as i64;
    let cur = control.cursor.load(Ordering::Relaxed) as i64;
    let clamp = |f: i64| f.clamp(0, n_frames.saturating_sub(1) as i64) as usize;

    match key.code {
        KeyCode::Char('q') | KeyCode::Esc => KeyOutcome::Break(Transition::Quit),
        KeyCode::Char(' ') => {
            control.paused.fetch_xor(true, Ordering::Relaxed);
            KeyOutcome::None
        }
        KeyCode::Right => {
            let target = clamp(cur + seek_frames);
            control.request_seek(target);
            KeyOutcome::Seek(target)
        }
        KeyCode::Left => {
            let target = clamp(cur - seek_frames);
            control.request_seek(target);
            KeyOutcome::Seek(target)
        }
        KeyCode::Char('n') | KeyCode::Down => KeyOutcome::Break(Transition::Next),
        KeyCode::Char('p') | KeyCode::Up => KeyOutcome::Break(Transition::Prev),
        KeyCode::Char('f') => KeyOutcome::Reveal,
        KeyCode::Char('t') => KeyOutcome::ToggleTheme,
        _ => KeyOutcome::None,
    }
}

/// Push one mono sample into the scope, coloring it via the stateful filterbank. The single place
/// the band-power squaring lives — shared by the live drain and the seek rebuild.
fn feed_scope(scope: &mut WaveScope, fb: &mut Filterbank, mono: f32) {
    let b = fb.process(mono);
    scope.push(mono, [b[0] * b[0], b[1] * b[1], b[2] * b[2]]);
}

/// Jump the waveform to a seek target. The scope is a live history of *played* audio, so after a
/// seek it would take a full window to catch up; instead, reset it and replay the ~WINDOW_SECS of
/// the decoded file leading up to `target` so the waveform reflects the new location immediately.
fn rebuild_wave_at(
    target: usize,
    frames: &[StereoFrame],
    file_rate: u32,
    scope: &mut WaveScope,
    fb: &mut Filterbank,
) {
    let window = (file_rate as f32 * WINDOW_SECS) as usize;
    let end = target.min(frames.len());
    let start = end.saturating_sub(window);
    *scope = WaveScope::new(file_rate);
    *fb = Filterbank::new(file_rate as f32, BAND_LOW_HZ, BAND_HIGH_HZ);
    for &[l, r] in &frames[start..end] {
        feed_scope(scope, fb, 0.5 * (l + r));
    }
}

/// Headless decode + metadata dump (`nanoplayer --probe <file>`): no TUI, no audio. A sanity
/// check for the symphonia integration — handy since the TUI itself needs a real terminal.
fn probe(path: &Path) {
    match decode(path) {
        Ok(d) => {
            let secs = d.frames.len() as f64 / d.sample_rate as f64;
            println!("file:    {path:?}");
            println!("frames:  {} @ {} Hz  ({:.1}s, {})", d.frames.len(), d.sample_rate, secs, if d.is_mono { "mono" } else { "stereo" });
            println!("title:   {:?}", d.tags.title);
            println!("artist:  {:?}", d.tags.artist);
            println!("album:   {:?}", d.tags.album);
            println!("date:    {:?}", d.tags.date);
            println!("track #: {:?}", d.tags.track_number);
            match d.cover {
                Some(img) => println!("cover:   {}x{} px decoded", img.width, img.height),
                None => println!("cover:   <none>"),
            }
        }
        Err(e) => {
            eprintln!("probe failed: {e}");
            std::process::exit(1);
        }
    }
}

fn main() {
    // Headless probe mode: `nanoplayer --probe <file>`.
    let argv: Vec<String> = std::env::args().collect();
    if argv.get(1).map(String::as_str) == Some("--probe") {
        match argv.get(2) {
            Some(p) => probe(Path::new(p)),
            None => {
                eprintln!("usage: nanoplayer --probe <audio-file>");
                std::process::exit(2);
            }
        }
        return;
    }

    let Some(initial) = resolve_path() else {
        eprintln!("usage: nanoplayer <audio-file>   (or set NANO_DEV_FILE)");
        std::process::exit(2);
    };

    let playlist = list_sibling_tracks(&initial);
    let mut index = index_of(&playlist, &initial);
    let truecolor = detect_truecolor();

    let Ok(_guard) = TermGuard::enter() else {
        eprintln!("[nanoplayer] not a terminal / can't enter raw mode");
        std::process::exit(1);
    };

    // Detect the terminal background now that raw mode is on (the OSC 11 query needs it). `t` flips
    // it at runtime if the guess is wrong.
    let mut bg_light = detect_bg_is_light();

    // OUTER loop: one iteration == one track played to a transition.
    let mut consecutive_failures = 0usize;
    'tracks: loop {
        let path = playlist[index].clone();

        let decoded = match decode(&path) {
            Ok(d) => {
                consecutive_failures = 0;
                d
            }
            Err(e) => {
                eprintln!("[nanoplayer] decode failed for {path:?}: {e} — skipping");
                consecutive_failures += 1;
                if consecutive_failures >= playlist.len() {
                    break 'tracks; // whole playlist is undecodable
                }
                index = (index + 1) % playlist.len();
                continue;
            }
        };

        let file_rate = decoded.sample_rate;
        let total_secs = decoded.frames.len() as f64 / file_rate as f64;
        let channels = if decoded.is_mono {
            Channels::Mono
        } else {
            Channels::Stereo
        };
        let name = file_name_str(&path).to_string();
        let tags = decoded.tags.clone();
        let cover = decoded.cover;
        let frames = Arc::new(decoded.frames);
        let n_frames = frames.len();

        let control = Arc::new(Control::new());
        let (producer, mut consumer) = rtrb::RingBuffer::<StereoFrame>::new(RING_CAPACITY);

        let stream = match start_playback(Arc::clone(&frames), file_rate, producer, Arc::clone(&control)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[nanoplayer] {e}");
                std::process::exit(1);
            }
        };

        // Per-track GUI-side DSP, all at this file's sample rate — the reuse seam.
        let mut loudness = LoudnessDsp::new(file_rate as f64, channels);
        let mut scope = WaveScope::new(file_rate);
        let mut filterbank = Filterbank::new(file_rate as f32, BAND_LOW_HZ, BAND_HIGH_HZ);
        let peak_decay = 0.25_f64.powf((PEAK_DECAY_MS / 1000.0 * file_rate as f64).recip()) as f32;
        let mut peak_l = 0.0f32;
        let mut peak_r = 0.0f32;

        let mut out = stdout();
        let frame_dt = Duration::from_micros(1_000_000 / TARGET_FPS);

        let transition = 'inner: loop {
            let frame_start = Instant::now();

            if control.ended.load(Ordering::Relaxed) {
                break 'inner Transition::Ended;
            }

            while event::poll(Duration::from_secs(0)).unwrap_or(false) {
                if let Ok(Event::Key(key)) = event::read() {
                    match handle_key(key, &control, n_frames, file_rate) {
                        KeyOutcome::Break(t) => break 'inner t,
                        KeyOutcome::Seek(target) => {
                            // Drop any queued pre-seek samples, then jump the waveform to `target`
                            // straight from the file so it doesn't drift in from the right.
                            while consumer.pop().is_ok() {}
                            rebuild_wave_at(target, &frames, file_rate, &mut scope, &mut filterbank);
                        }
                        KeyOutcome::Reveal => {
                            // Reveal the playing file in Finder (macOS). Fire-and-forget.
                            let _ = std::process::Command::new("open").arg("-R").arg(&path).spawn();
                        }
                        KeyOutcome::ToggleTheme => bg_light = !bg_light,
                        KeyOutcome::None => {}
                    }
                }
            }

            // Drain the ring → feed meters + scope + filterbank (the audio→GUI seam).
            while let Ok([l, r]) = consumer.pop() {
                loudness.push_frame(l, r);
                peak_l = l.abs().max(peak_l * peak_decay);
                peak_r = r.abs().max(peak_r * peak_decay);
                feed_scope(&mut scope, &mut filterbank, 0.5 * (l + r));
            }

            let (cols, rows) = terminal::size().unwrap_or((80, 24));
            let pos_secs = control.cursor.load(Ordering::Relaxed) as f64 / file_rate as f64;
            let view = View {
                name: &name,
                tags: &tags,
                cover: cover.as_ref(),
                scope: &scope,
                momentary: loudness.momentary_lufs(),
                short: loudness.short_term_lufs(),
                integrated: loudness.integrated_lufs(),
                peak_l,
                peak_r,
                pos_secs,
                total_secs,
                paused: control.paused.load(Ordering::Relaxed),
                track_idx: index,
                track_count: playlist.len(),
                truecolor,
                bg_light,
            };
            let buf = render_frame(&view, cols, rows);
            let _ = out.write_all(buf.as_bytes());
            let _ = out.flush();

            if let Some(rem) = frame_dt.checked_sub(frame_start.elapsed()) {
                std::thread::sleep(rem);
            }
        };

        drop(stream); // stop audio before the next track's stream is built

        match transition {
            Transition::Quit => break 'tracks,
            Transition::Next | Transition::Ended => index = (index + 1) % playlist.len(),
            Transition::Prev => index = (index + playlist.len() - 1) % playlist.len(),
        }
    }

    let mut out = stdout();
    let _ = crossterm::execute!(out, terminal::Clear(ClearType::All));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering;

    #[test]
    fn natural_sort_orders_track_numbers() {
        assert_eq!(natural_cmp("track2.mp3", "track10.mp3"), Ordering::Less);
        assert_eq!(natural_cmp("10", "9"), Ordering::Greater);
        assert_eq!(natural_cmp("a", "B"), Ordering::Less); // case-insensitive
        assert_eq!(natural_cmp("song.mp3", "song.mp3"), Ordering::Equal);
    }

    #[test]
    fn wavescope_render_survives_zero_cols() {
        // terminal::size() can report 0 columns mid-resize; render must not panic (regression).
        let mut scope = WaveScope::new(48_000);
        scope.push(0.5, [0.1, 0.2, 0.3]); // non-empty window — the case that used to index grid[0]
        assert_eq!(scope.render(0, 3, true, false).len(), 3);
        assert!(scope.render(10, 0, true, false).is_empty());
    }

    #[test]
    fn rebuild_wave_at_jumps_to_target() {
        let rate = 48_000u32;
        let window = (rate as f32 * WINDOW_SECS) as usize;
        let frames: Vec<StereoFrame> = vec![[0.0, 0.0]; window * 2]; // 8s of audio
        let mut scope = WaveScope::new(rate);
        let mut fb = Filterbank::new(rate as f32, BAND_LOW_HZ, BAND_HIGH_HZ);
        // Seek deep into the file → the window fills completely.
        rebuild_wave_at(window + 1000, &frames, rate, &mut scope, &mut fb);
        assert_eq!(scope.samples.len(), window);
        // Seek near the very start → only the samples that precede the target.
        rebuild_wave_at(10, &frames, rate, &mut scope, &mut fb);
        assert_eq!(scope.samples.len(), 10);
    }

    #[test]
    fn light_theme_darkens_broadband() {
        // Broadband (white) must read DARK on a light bg, and bright on a dark bg.
        let white = [1.0, 1.0, 1.0];
        let light = tone(white, true);
        let dark = tone(white, false);
        let lum = |c: [f32; 3]| 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
        assert!(lum(light) < 0.3, "broadband on light bg should be dark, got {light:?}");
        assert!(lum(dark) > 0.7, "broadband on dark bg should be bright, got {dark:?}");
        // A pure hue keeps its identity (red dominant) on a light bg, just darker.
        let red = tone([1.0, 0.0, 0.0], true);
        assert!(red[0] > red[1] && red[0] > red[2], "red stays red, got {red:?}");
    }

    #[test]
    fn osc11_luminance_parses() {
        // Black bg → ~0, white bg → ~1.
        assert!(parse_osc11_luminance("\x1b]11;rgb:0000/0000/0000\x07").unwrap() < 0.01);
        assert!(parse_osc11_luminance("\x1b]11;rgb:ffff/ffff/ffff\x07").unwrap() > 0.99);
        assert!(parse_osc11_luminance("nonsense").is_none());
    }

    #[test]
    fn cube_index_maps_corners() {
        assert_eq!(cube_index(0, 0, 0), 16);
        assert_eq!(cube_index(255, 255, 255), 231);
    }

    #[test]
    fn square_cover_fills_a_double_width_grid() {
        // Square source in a square pixel budget (cols == rows*2) → fully painted, no letterbox.
        let img = Rgb8Image {
            width: 64,
            height: 64,
            pixels: vec![20; 64 * 64 * 3],
        };
        let lines = img.render_half_blocks(40, 20, true);
        assert_eq!(lines.len(), 20);
        assert!(lines.iter().all(|l| l.starts_with("\x1b[38;2;")));
    }

    #[test]
    fn wide_cover_letterboxes() {
        // 2:1 source in a square budget → top/bottom rows blank.
        let img = Rgb8Image {
            width: 128,
            height: 64,
            pixels: vec![20; 128 * 64 * 3],
        };
        let lines = img.render_half_blocks(40, 20, true);
        assert!(lines.first().unwrap().contains(' '));
        assert!(lines.last().unwrap().contains(' '));
    }
}
