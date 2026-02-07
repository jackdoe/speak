# Speak

Push-to-talk transcription for macOS. Hold a key, speak, release — your words appear wherever your cursor is.

Uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal GPU acceleration on Apple Silicon.

## Features

- **Push-to-talk** — F12 to transcribe, F11 to transcribe + send (hits Return)
- **Menu bar app** — lives in the status bar, no dock icon
- **Metal accelerated** — runs whisper.cpp on the GPU
- **Voice activity detection** — filters silence, supports 10+ minute recordings with pauses
- **Recording overlay** — floating indicator with VAD state, duration, and audio level
- **Model management** — download models from HuggingFace directly in the app
- **Configurable** — hotkeys, output mode (type/paste), VAD thresholds, all whisper.cpp parameters
- **Instant start** — optional always-on microphone for zero-latency recording

## Requirements

- macOS 14+
- Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools
- CMake (`brew install cmake`)

## Build

```bash
git clone --recursive https://github.com/user/speak.git
cd speak
make app
```

This builds whisper.cpp with Metal, compiles the Swift app, and creates `Speak.app`.

To install to `/Applications`:

```bash
make install
```

## First Launch

The app guides you through setup:

1. **Microphone permission** — for audio capture
2. **Accessibility permission** — for global hotkeys and text output
3. **Model download** — pick a whisper model (Large V3 Turbo Q5 recommended)
4. **Preferences** — configure hotkeys and behavior

## Usage

- **F12** (hold) — record speech, (release) — transcribe and output text
- **F11** (hold) — same as F12 but also presses Return after (for chat apps)
- **Menu bar icon** — switch models, toggle mic warm, open settings

## Make Targets

| Command | Description |
|---------|-------------|
| `make whisper` | Build whisper.cpp with Metal |
| `make build` | Build whisper.cpp + release binary |
| `make debug` | Build debug binary |
| `make run` | Build debug + run |
| `make app` | Create Speak.app bundle |
| `make install` | Copy Speak.app to /Applications |
| `make uninstall` | Remove from /Applications |
| `make clean` | Remove build artifacts |
| `make models` | Download base.en + medium.en + large-v3 models |
| `make models-large-turbo-q5` | Download large-v3-turbo-q5 (recommended) |

## Project Structure

```
Sources/Speak/
├── App/              HotkeyManager, StatusBarController, SpeakApp
├── Audio/            AudioEngine, RingBuffer, VoiceActivityDetector
├── Whisper/          WhisperContext, ModelManager, ModelDownloader, WhisperSettings
├── Pipeline/         TranscriptionPipeline
├── UI/               SettingsView, RecordingOverlay, OnboardingView
├── Utils/            TextOutput, PerformanceMonitor, LoginItemManager
└── Benchmark/        BenchmarkRunner, BenchmarkView
```

## Models

Models are stored in `~/Library/Application Support/Speak/models/`. Download via the app settings or CLI:

| Model | Size | Speed (5s audio on M1) |
|-------|------|----------------------|
| tiny.en | 75 MB | ~0.15s |
| base.en | 142 MB | ~0.3s |
| small.en | 466 MB | ~0.8s |
| large-v3-turbo-q5 | 547 MB | ~0.5s |
| medium.en | 1.5 GB | ~2.5s |
| large-v3 | 2.9 GB | ~5s |

## Built by

Written by Claude Opus 4.6 in team mode — architecture, research, and implementation done by a coordinated team of specialist agents (ML engineer, audio engineer, UI engineer) working in parallel.

## License

whisper.cpp is MIT licensed. This project wraps it with a native macOS interface.
