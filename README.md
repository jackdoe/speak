# Speak

Push-to-talk transcription for macOS and Linux (Hyprland). Hold a key, speak, release — your words appear wherever your cursor is, with punctuation and capitalisation, fully on-device.

Both platforms run NVIDIA [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2).

## macOS

A menu bar app running Parakeet TDT on Core ML (Apple Neural Engine), with its own TDT decoder — no third-party Swift packages. About 60 ms from key release to text for a one-word dictation on an M1 Max, 85 ms for 6 s of speech, 340 ms for 26 s.

- **Hotkeys** — hold **F12** to dictate and type the text followed by a space; **Shift+F12** types it and presses Return; **F11** sends it to Claude Code in kitty (below). Carbon hot keys, real press and release, no Accessibility permission needed for them. On a laptop keyboard hold fn, or turn on *Use F1, F2, etc. keys as standard function keys*; F11 is *Show Desktop* by default, switch that off in Keyboard Shortcuts › Mission Control.
- **Microphone** — always open (so the orange microphone dot stays on) at 16 kHz into a 10-minute ring buffer; the 250 ms before the key press and 150 ms after the release are kept, so the first syllable is never lost.
- **Typing** — Unicode keyboard events, any language or symbol; needs Accessibility permission, which Speak asks for at launch.
- **Menu bar** — grey when idle, red while recording, amber while transcribing; the menu shows the last timing (never the text), Settings… and Quit.
- **Settings** — microphone (default: the system default) and Launch at login.
- **Privacy** — the transcript only ever goes to the app you are typing in. Nothing is logged unless you run with `--verbose`, and then only key presses, durations, peak level and character counts.

Requirements: macOS 14+, Apple Silicon, Xcode command line tools, `jq` (built into macOS 15+, `brew install jq` on 14).

```bash
make install
```

This builds and signs `Speak.app`, downloads the model and installs the app to `/Applications`. Open it, allow the microphone and Accessibility, and turn on Launch at login in Settings. `make install` signs ad hoc by default, so macOS forgets the Accessibility grant on every rebuild; sign with your own identity to keep it: `make install SIGN_ID="Apple Development: …"`.

### The model

`make model` downloads the Core ML conversion [`FluidInference/parakeet-tdt-0.6b-v2-coreml`](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) at a pinned revision into `~/Library/Application Support/Speak/parakeet-tdt-0.6b-v2-coreml` (450 MB), checking every file against the SHA-256 or git hash Hugging Face publishes for it. Four bundles make the pipeline:

| Bundle | Input → output | Runs on |
|---|---|---|
| `Preprocessor` | 16 kHz audio + length → 128 log-mel features, normalised per feature | any (`.all`) |
| `Encoder` | mel `[1, 128, 1501]` + length → `[1, 1024, 188]` (FastConformer, 6-bit palettised) | Neural Engine |
| `Decoder` | previous token + LSTM state → prediction | CPU |
| `JointDecision` | encoder frame + prediction → token and duration | CPU |

The encoder takes exactly 15 s. Every dictation is padded to that window and its true length passed in, so the model masks the padding out and Core ML never sees a new shape. Greedy TDT decoding is the same loop as on Linux. Longer dictations are split into 15 s windows that overlap by 2 s on each side of a cut; the cut goes between two words in the middle of a sentence, taken from the first window's own output, so neither window has to decide a sentence boundary on its own.

### Claude Code in kitty

F11 finds the most recently focused kitty tab running `claude` — wherever your focus is — pastes the transcript there and presses Return, over kitty's remote control socket. Add to `~/.config/kitty/kitty.conf`:

```
allow_remote_control socket-only
listen_on unix:${HOME}/Library/Caches/kitty-speak/kitty
```

Create the directory once with `mkdir -m 700 ~/Library/Caches/kitty-speak` (Speak also creates it at launch), then quit kitty completely and start it again.

```bash
/Applications/Speak.app/Contents/MacOS/Speak --verbose      # log key presses and timings, never text
/Applications/Speak.app/Contents/MacOS/Speak recording.wav  # transcribe any audio file, print timing
```

| Command | Description |
|---|---|
| `make build` | Release binary |
| `make app` | Signed `Speak.app` in `.build/` |
| `make model` | Download and verify the model |
| `make install` | `app` + `model`, copy to `/Applications` |
| `make uninstall` | Remove from `/Applications` |
| `make clean` | Remove build artifacts |

## Linux (Hyprland)

A native Wayland daemon running NVIDIA [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) on CUDA through ONNX Runtime. 30–110 ms from key release to text on an RTX 3080 for dictations up to 20 s, with punctuation and capitalisation. Audio is padded to a fixed 20 s shape with the true length passed to the encoder, so the GPU never re-plans its kernels and the padding is masked out of the result.

- **Hotkeys** — Hyprland global shortcuts (`hyprland-global-shortcuts-v1`), real press and release events
- **Typing** — virtual keyboard protocol (`zwp_virtual_keyboard_v1`), any Unicode, no `wtype`/`ydotool`
- **Status** — `speak --waybar` streams state to a waybar custom module: red while recording, amber while transcribing
- **Microphone** — always open at 16 kHz; the 250 ms before the key press is kept, so the first syllable is never lost

Requirements: Hyprland, NVIDIA driver with CUDA 12 support, cuDNN 9, PipeWire/PulseAudio, `libwayland-client`, `libxkbcommon`, `libpulse`. The build fetches ONNX Runtime, kaldi-native-fbank and the CUDA 12.9 runtime.

```bash
make linux-install
```

This builds `speak`, downloads the model to `~/.local/share/speak/parakeet-tdt-0.6b-v2`, and installs to `~/.local/bin` and `~/.local/lib/speak`. Then in `hyprland.conf`:

```
exec-once = speak
bind = , Page_Down, global, speak:talk
bind = SHIFT, Page_Down, global, speak:send
bind = , Page_Up, global, speak:claude
```

`speak:talk` types the transcript; `speak:send` types it and presses Return. `speak:claude` sends it to Claude Code wherever focus is: speak asks kitty over its remote control socket for the most recently focused tab running `claude`, pastes the transcript there and presses Return. This needs in `kitty.conf`:

```
allow_remote_control socket-only
listen_on unix:${XDG_RUNTIME_DIR}/kitty
```

 In waybar:

```json
"custom/speak": { "exec": "speak --waybar", "return-type": "json", "restart-interval": 1 }
```

```bash
speak --devices              # list audio sources
speak --device SOURCE        # use a specific source
speak --cpu                  # run without CUDA
speak --verbose              # log key presses and timings (never the text)
speak recording.wav          # transcribe a 16 kHz wav, print timing
```

## Built by

Written by Claude Opus 4.6 in team mode — architecture, research, and implementation done by a coordinated team of specialist agents (ML engineer, audio engineer, UI engineer) working in parallel.

## License

Parakeet TDT 0.6B v2 is by NVIDIA, licensed CC-BY-4.0; the Core ML conversion is by FluidInference, CC-BY-4.0.
