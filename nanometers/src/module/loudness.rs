//! Loudness Module (ADRs 0006 / 0005 + `docs/specs/loudness-module.md`).
//!
//! Wraps the hand-rolled BS.1770 DSP core (`crate::loudness::LoudnessDsp`, ebur128-verified) into a
//! GUI-side Module: fold each frame's samples in `update`, render the Momentary / Short-term /
//! Integrated values as `wgpu_text` numeric readouts (ADR 0005, embedded OFL JetBrains Mono).
//!
//! Channel weighting is load-bearing (spec): a mono stream must be measured as a SINGLE channel —
//! the plugin duplicates a mono input to L = R, so summing it reads +3 LU hot. `Channels` is
//! derived from `FrameContext::mono`.
//!
//! Text positioning: the brush is sized to the viewport and text is placed in column-local pixel
//! coords; the host's `set_viewport` then maps the brush's clip output into this column (so the
//! readouts land column-local without the Module knowing the surface size).

use wgpu_text::glyph_brush::ab_glyph::FontRef;
use wgpu_text::glyph_brush::{Section, Text};
use wgpu_text::{BrushBuilder, TextBrush};

use super::{EventStatus, FrameContext, Module, Rect};
use crate::loudness::{Channels, LoudnessDsp};

/// Embedded OFL font (JetBrains Mono, tabular figures — values don't jitter as digits change).
const FONT: &[u8] = include_bytes!("../../assets/fonts/JetBrainsMono-Regular.ttf");

type Brush = TextBrush<FontRef<'static>>;

const TEXT_COLOR: [f32; 4] = [0.88, 0.93, 1.0, 1.0];

pub struct LoudnessModule {
    dsp: Option<LoudnessDsp>,
    sample_rate: f32,
    channels: Channels,

    brush: Brush,
    /// Current `resize_view` size, so we only re-project the brush when the viewport changes.
    brush_size: (u32, u32),
    /// Frame counter for the optional `NANO_DEBUG_LOUDNESS` value log (dev aid, off by default).
    dbg_count: u32,
}

impl LoudnessModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        // Single-sample to match the host's shared pass (0007); format must equal the surface's.
        let brush = BrushBuilder::using_font_bytes(FONT)
            .expect("embedded JetBrains Mono is a valid OFL TTF")
            .build(device, 256, 256, format);
        Self {
            dsp: None,
            sample_rate: 0.0,
            channels: Channels::Stereo,
            brush,
            brush_size: (256, 256),
            dbg_count: 0,
        }
    }
}

/// Format one time-scale readout, e.g. `M   -14.2`. Non-finite (no measurement yet) → dashes.
fn fmt_lufs(label: &str, v: f64) -> String {
    if v.is_finite() {
        format!("{label} {v:>7.1}")
    } else {
        format!("{label}    --.-")
    }
}

impl Module for LoudnessModule {
    fn update(&mut self, ctx: &FrameContext, _queue: &wgpu::Queue) {
        if ctx.sample_rate <= 0.0 {
            return; // unknown rate — meter idles (spec)
        }
        let channels = if ctx.mono {
            Channels::Mono
        } else {
            Channels::Stereo
        };
        if self.dsp.is_none() || ctx.sample_rate != self.sample_rate || channels != self.channels {
            self.sample_rate = ctx.sample_rate;
            self.channels = channels;
            self.dsp = Some(LoudnessDsp::new(ctx.sample_rate as f64, channels));
        }
        if let Some(dsp) = self.dsp.as_mut() {
            for &[l, r] in ctx.new {
                dsp.push_frame(l, r);
            }
        }

        // Dev aid (off by default): log the live values so the meter can be verified even when a
        // system overlay hides the on-screen text. Throttled to ~once/2s at 60 fps.
        self.dbg_count = self.dbg_count.wrapping_add(1);
        if self.dbg_count % 120 == 0 && std::env::var_os("NANO_DEBUG_LOUDNESS").is_some() {
            if let Some(dsp) = self.dsp.as_ref() {
                eprintln!(
                    "[loudness] M={:.1} S={:.1} I={:.1} LUFS ({:?})",
                    dsp.momentary_lufs(),
                    dsp.short_term_lufs(),
                    dsp.integrated_lufs(),
                    self.channels
                );
            }
        }
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
    ) {
        // Re-project the brush onto the viewport when its size changes (so column-local pixel
        // positions map correctly through the host's set_viewport).
        let size = (viewport.w.max(1.0) as u32, viewport.h.max(1.0) as u32);
        if size != self.brush_size {
            self.brush
                .resize_view(size.0 as f32, size.1 as f32, queue);
            self.brush_size = size;
        }

        let (m, s, i) = self
            .dsp
            .as_ref()
            .map(|d| (d.momentary_lufs(), d.short_term_lufs(), d.integrated_lufs()))
            .unwrap_or((f64::NEG_INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY));

        // Dev aid (off by default): log the live values so the meter can be verified even when a
        // system overlay hides the on-screen text. Throttled to ~once/2s at 60 fps.
        self.dbg_count = self.dbg_count.wrapping_add(1);
        if self.dbg_count % 120 == 0 && std::env::var_os("NANO_DEBUG_LOUDNESS").is_some() {
            eprintln!("[loudness] M={m:.1} S={s:.1} I={i:.1} LUFS ({:?})", self.channels);
        }

        let lines = [fmt_lufs("M", m), fmt_lufs("S", s), fmt_lufs("I", i)];
        let scale = (viewport.h * 0.11).clamp(15.0, 44.0);
        let x = viewport.w * 0.08;
        let y0 = viewport.h * 0.14;
        let dy = scale * 1.5;

        let sections: Vec<Section> = lines
            .iter()
            .enumerate()
            .map(|(idx, text)| {
                Section::default()
                    .with_screen_position((x, y0 + idx as f32 * dy))
                    .with_bounds((viewport.w, viewport.h))
                    .add_text(Text::new(text).with_scale(scale).with_color(TEXT_COLOR))
            })
            .collect();

        // Glyph upload; safe to ignore a transient cache error (drops this frame's text).
        let _ = self.brush.queue(device, queue, &sections);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        self.brush.draw(rpass);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored // reset affordance lands in Phase E
    }

    fn save_config(&self) -> Vec<u8> {
        Vec::new() // opaque config (target/scale) lands in Phase F
    }

    fn load_config(&mut self, _bytes: &[u8]) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_lufs_finite_and_silent() {
        assert_eq!(fmt_lufs("M", -14.2), "M   -14.2");
        assert_eq!(fmt_lufs("I", f64::NEG_INFINITY), "I    --.-");
    }
}
