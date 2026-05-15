# nanometers

Chill open-source audio meter plugin. Waveform, spectrum, and stereo visualizations with a phosphor-trail aesthetic.

## Status

Early bootstrap. Not yet usable.

## Building

```sh
# CLAP + VST3 bundle
cargo xtask bundle nanometers --release

# Standalone binary (uses default audio device via cpal)
cargo run --release --bin nanometers
```

Built bundles end up in `target/bundled/`.

### Installing on macOS

```sh
# CLAP
cp -r target/bundled/nanometers.clap ~/Library/Audio/Plug-Ins/CLAP/

# AU (after clap-wrapper step — TODO)
```

## License

MIT.
