//! nanometers — chill open-source audio meter plugin.
//!
//! `lib.rs` owns the plugin-side (audio thread): the `Plugin` impl, parameters, and the
//! `Shared` handoff state read by the GUI. Everything window-/render-side lives in
//! `editor.rs`.

use atomic_float::AtomicF32;
use crossbeam::atomic::AtomicCell;
use nih_plug::prelude::*;
use std::{
    num::NonZeroU32,
    sync::{Arc, Mutex, atomic::Ordering},
};

mod editor;
use editor::{EditorState, NanometersEditor};

#[cfg(feature = "dev-player")]
mod dev;

/// Window default, in logical pixels.
pub const INITIAL_WIDTH: u32 = 720;
pub const INITIAL_HEIGHT: u32 = 420;

/// Time for the peak meter to drop 12 dB after silence.
const PEAK_DECAY_MS: f64 = 250.0;

/// Capacity of the audio→GUI sample ring (stereo pairs). 32k pairs at 48 kHz is ~680 ms —
/// plenty of headroom even if the GUI hiccups for several frames.
pub const SAMPLE_RING_CAPACITY: usize = 32768;

/// One interleaved L/R audio frame. Wire format for the audio→GUI ring buffer.
pub type StereoFrame = [f32; 2];

/// Shared state between the audio thread (writer) and the GUI thread (reader).
///
/// The audio thread MUST NOT touch `samples_rx`. The Mutex is only ever taken by the GUI thread,
/// which makes it effectively uncontended — `lock()` never blocks for any meaningful duration.
pub struct Shared {
    pub peak_l: AtomicF32,
    pub peak_r: AtomicF32,
    pub samples_rx: Mutex<rtrb::Consumer<StereoFrame>>,
}

pub struct Nanometers {
    params: Arc<NanometersParams>,
    shared: Arc<Shared>,

    /// Audio-thread-owned producer for the sample ring. Wait-free push. `Option` so the
    /// dev-player (when enabled) can take ownership and feed the ring from a decoded file
    /// instead — rtrb is single-producer, so only one side may hold this.
    samples_tx: Option<rtrb::Producer<StereoFrame>>,

    /// Per-sample multiplicative decay for peak meter ballistics. Computed in `initialize`
    /// from the host's sample rate so the visible decay is independent of rate.
    peak_decay_per_sample: f32,
}

#[derive(Params)]
pub struct NanometersParams {
    #[persist = "editor-state"]
    pub(crate) editor_state: Arc<EditorState>,
}

impl Default for Nanometers {
    fn default() -> Self {
        let (samples_tx, samples_rx) = rtrb::RingBuffer::<StereoFrame>::new(SAMPLE_RING_CAPACITY);
        Self {
            params: Arc::new(NanometersParams::default()),
            shared: Arc::new(Shared {
                peak_l: AtomicF32::new(0.0),
                peak_r: AtomicF32::new(0.0),
                samples_rx: Mutex::new(samples_rx),
            }),
            samples_tx: Some(samples_tx),
            peak_decay_per_sample: 1.0,
        }
    }
}

impl Default for NanometersParams {
    fn default() -> Self {
        Self {
            editor_state: EditorState::from_size((INITIAL_WIDTH, INITIAL_HEIGHT)),
        }
    }
}

impl Plugin for Nanometers {
    const NAME: &'static str = "nanometers";
    const VENDOR: &'static str = "willeasp";
    const URL: &'static str = "https://github.com/willeasp/nanometers";
    const EMAIL: &'static str = "wille.asp@live.se";
    const VERSION: &'static str = env!("CARGO_PKG_VERSION");

    const AUDIO_IO_LAYOUTS: &'static [AudioIOLayout] = &[
        AudioIOLayout {
            main_input_channels: NonZeroU32::new(2),
            main_output_channels: NonZeroU32::new(2),
            ..AudioIOLayout::const_default()
        },
        // Mono-input layout so the meter accepts mono sources, and so the standalone can bind a
        // mono input device (e.g. a laptop mic) via `--audio-layout 2`. Output stays stereo
        // because macOS speakers don't expose a 1-channel output config — the meter duplicates
        // the mono input to both channels anyway.
        AudioIOLayout {
            main_input_channels: NonZeroU32::new(1),
            main_output_channels: NonZeroU32::new(2),
            ..AudioIOLayout::const_default()
        },
    ];

    const SAMPLE_ACCURATE_AUTOMATION: bool = false;

    type SysExMessage = ();
    type BackgroundTask = ();

    fn params(&self) -> Arc<dyn Params> {
        self.params.clone()
    }

    fn editor(&mut self, _async_executor: AsyncExecutor<Self>) -> Option<Box<dyn Editor>> {
        Some(Box::new(NanometersEditor {
            params: Arc::clone(&self.params),
            shared: Arc::clone(&self.shared),

            #[cfg(target_os = "macos")]
            scaling_factor: AtomicCell::new(None),
            #[cfg(not(target_os = "macos"))]
            scaling_factor: AtomicCell::new(Some(1.0)),
        }))
    }

    fn initialize(
        &mut self,
        _audio_io_layout: &AudioIOLayout,
        buffer_config: &BufferConfig,
        _context: &mut impl InitContext<Self>,
    ) -> bool {
        // Solve `decay^N = 0.25` for the per-sample factor where N = sr * decay_ms / 1000.
        let samples_for_12db_drop = buffer_config.sample_rate as f64 * PEAK_DECAY_MS / 1000.0;
        self.peak_decay_per_sample = 0.25_f64.powf(samples_for_12db_drop.recip()) as f32;

        // Dev-only: if a song was requested, hand the ring producer to the file player thread. It
        // takes over feeding the waveform (and plays the file out loud), so `process` stops
        // pushing — see the `Option` guard there. Run with `--backend dummy`.
        #[cfg(feature = "dev-player")]
        if let Ok(path) = std::env::var("NANO_DEV_FILE") {
            if let Some(producer) = self.samples_tx.take() {
                dev::spawn(std::path::PathBuf::from(path), producer);
            }
        }

        true
    }

    fn process(
        &mut self,
        buffer: &mut Buffer,
        _aux: &mut AuxiliaryBuffers,
        _context: &mut impl ProcessContext<Self>,
    ) -> ProcessStatus {
        // Hosts can call process() with the editor closed. We can save a meaningful chunk of
        // CPU by skipping all the meter work — the audio still passes through unchanged because
        // we never mutate samples in this plugin to begin with.
        if !self.params.editor_state.is_open() {
            return ProcessStatus::Normal;
        }

        let decay = self.peak_decay_per_sample;
        let mut peak_l = self.shared.peak_l.load(Ordering::Relaxed);
        let mut peak_r = self.shared.peak_r.load(Ordering::Relaxed);

        for channel_samples in buffer.iter_samples() {
            // Pull L and R; fall back to duplicating L for mono sources even though our
            // declared layout is stereo, so we don't spike on weird configs.
            let mut iter = channel_samples.into_iter();
            let l = iter.next().copied().unwrap_or(0.0);
            let r = iter.next().copied().unwrap_or(l);

            let abs_l = l.abs();
            peak_l = if abs_l > peak_l { abs_l } else { peak_l * decay };
            let abs_r = r.abs();
            peak_r = if abs_r > peak_r { abs_r } else { peak_r * decay };

            // Wait-free push. If the ring is somehow full (GUI starved for ~700 ms) we drop
            // the oldest-still-unread frame by discarding the new one. Acceptable for a meter.
            // `samples_tx` is `None` only when the dev-player owns the ring instead.
            if let Some(tx) = self.samples_tx.as_mut() {
                let _ = tx.push([l, r]);
            }
        }

        self.shared.peak_l.store(peak_l, Ordering::Relaxed);
        self.shared.peak_r.store(peak_r, Ordering::Relaxed);

        ProcessStatus::Normal
    }
}

impl ClapPlugin for Nanometers {
    const CLAP_ID: &'static str = "com.willeasp.nanometers";
    const CLAP_DESCRIPTION: Option<&'static str> = Some(
        "Chill open-source audio meter plugin with waveform, spectrum, and stereo visualizations.",
    );
    const CLAP_MANUAL_URL: Option<&'static str> = Some(Self::URL);
    const CLAP_SUPPORT_URL: Option<&'static str> = None;
    const CLAP_FEATURES: &'static [ClapFeature] = &[
        ClapFeature::AudioEffect,
        ClapFeature::Analyzer,
        ClapFeature::Stereo,
    ];
}

nih_export_clap!(Nanometers);
