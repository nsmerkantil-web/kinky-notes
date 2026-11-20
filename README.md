# Kinky Notes

**A local-first meeting recorder and AI notetaker for macOS, with Markdown notes you can open in Obsidian.**

Hey! This is my first project on GitHub, and I’m still building it. I started Kinky Notes because I wanted the convenience of Granola with one thing I cared a lot about: a meeting could go from audio to transcript to notes entirely on my Mac.

Kinky Notes records your microphone and system audio without sending a bot into the call. WhisperKit transcribes on-device, and you can use a local Ollama model to write a summary. With that setup, the recording, transcript, and summary stay on your Mac. Your notes are plain Markdown files you can open and edit in Obsidian.

## Try the beta

[Download the early beta](https://github.com/nsmerkantil-web/kinky-notes/releases/tag/v1.0.0-local-beta) for Apple Silicon Macs running macOS 15 or later. The release page explains how to join the two download parts and verify the checksum. The beta uses a local signature, so macOS Gatekeeper may block it.

I’ll share updates here as I go, including what’s working, what’s still rough, and what I’m learning along the way. If you try it, I’d love to hear what happened. A bug report, an idea, or even a quick “it worked on my Mac” would mean a lot. [Leave feedback on GitHub](https://github.com/nsmerkantil-web/kinky-notes/issues).

Thanks for giving my first project a little of your time. Made with love. ❤️

## Install from the disk image

1. Verify the DMG against its companion `.sha256` file. Open the image and drag the app to `~/Applications` or `/Applications`.
2. For automated setup, give Codex [CODEX_START_PROMPT.md](CODEX_START_PROMPT.md) and the path to the DMG. Codex can find or install Ollama, configure a local Llama model, and run the checks. [Ollama for macOS](https://docs.ollama.com/macos)
3. Open the app and grant macOS permission to record your microphone and system audio. The app stores Markdown notes in your Documents folder by default and keeps audio and its library in Application Support. [Obsidian storage guide](docs/OBSIDIAN_STORAGE.md)

The app bundles WhisperKit 0.9.4, the `openai_whisper-large-v3_turbo` Core ML model, and the `openai/whisper-large-v3` tokenizer. If you do not already have a local Llama model, setup downloads it through Ollama. Allow about 2 GB for `llama3.2:3b` or 1.3 GB for `llama3.2:1b`. The transcription audit covers Russian and English. Russian summaries need a separate quality check because Russian is outside Llama 3.2’s officially supported languages. [Llama 3.2](https://ollama.com/library/llama3.2) · [Whisper Core ML weights](https://huggingface.co/argmaxinc/whisperkit-coreml) · [Whisper tokenizer](https://huggingface.co/openai/whisper-large-v3)

## Build and audit

Copy the `Project` folder from the DMG to a writable location. Building requires Swift 6 and the macOS 15 SDK or later. SwiftPM fetches the versions pinned in `Package.resolved` on the first build.

Set `BUNDLED_APP` to the actual path of the app on the mounted disk image, or omit the two model source overrides if the assets are already in the default local model directories used by the build script.

```zsh
swift test
BUNDLED_APP="/path/to/mounted/application.app"
ASR_SOURCE="$BUNDLED_APP/Contents/Resources/OfflineASR/Model" \
TOKENIZER_SOURCE="$BUNDLED_APP/Contents/Resources/OfflineASR/Hub/models/openai/whisper-large-v3" \
PACKAGE_HANDOFF=1 ./scripts/package-app.sh
```

Build artifacts go to `dist/handoff/`. See [AGENTS.md](AGENTS.md) for project instructions.

```zsh
./scripts/setup-local.sh "/path/to/installed/application.app" llama3.2:3b
./scripts/audit-handoff.sh "/path/to/handoff.dmg" llama3.2:3b
```

Setup checks that bundled Whisper loads and that the local Llama model responds before saving the profile. The audit mounts the DMG read-only, verifies the signature, loads Whisper with network access disabled, and processes synthetic Russian and English audio through the standard queue. It then reopens the saved library in a fresh process. Live microphone and system audio capture require a separate check with macOS permissions granted.

## Signing

macOS Gatekeeper may block the locally signed beta. For external distribution, set `DEVELOPER_ID_APPLICATION` and `NOTARY_KEYCHAIN_PROFILE` when packaging. See `SIGNING_STATUS.txt` inside the local beta DMG for its signing status.
