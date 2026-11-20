# Kinky Notes

**A local-first meeting recorder and AI notetaker for macOS, with Markdown notes you can open in Obsidian.**

Hey! This is my first project on GitHub, and I’m still building it. I started Kinky Notes because I wanted the convenience of Granola with one thing I cared a lot about: a meeting could go from audio to transcript to notes entirely on my Mac.

Kinky Notes records your microphone and system audio without sending a bot into the call. WhisperKit transcribes on-device, and you can use a local Ollama model to write a summary. With that setup, the recording, transcript, and summary stay on your Mac. Your notes are plain Markdown files you can open and edit in Obsidian.

## Try the beta

[Download the early beta](https://github.com/nsmerkantil-web/kinky-notes/releases/tag/v1.0.0-local-beta) for Apple Silicon Macs running macOS 15 or later. The current download still carries the old name, A-notes. The release page explains how to join the two download parts and verify the checksum. The beta uses a local signature, so macOS Gatekeeper may block it.

I’ll share updates here as I go, including what’s working, what’s still rough, and what I’m learning along the way. If you try it, I’d love to hear what happened. A bug report, an idea, or even a quick “it worked on my Mac” would mean a lot. [Leave feedback on GitHub](https://github.com/nsmerkantil-web/kinky-notes/issues).

Thanks for giving my first project a little of your time. Made with love. ❤️

## Установка из архива

1. На Mac с Apple Silicon и macOS 15+ проверьте SHA-256 файла DMG по соседнему файлу `.sha256`. Откройте DMG и скопируйте `A-notes.app` в `~/Applications` или `/Applications`.
2. Для автоматической настройки передайте Codex файл [CODEX_START_PROMPT.md](CODEX_START_PROMPT.md) и путь к DMG. Codex найдёт или установит Ollama, подключит локальную Llama и запустит проверки. [Руководство по Ollama для macOS](https://docs.ollama.com/macos).
3. Для записи в открытом приложении выдайте системные разрешения на микрофон и системный звук. Тексты по умолчанию хранятся в `~/Documents/A-notes`, аудио и библиотека в `~/Library/Application Support/AntonNotes`. [Хранение в Obsidian](docs/OBSIDIAN_STORAGE.md).

В `A-notes.app` уже есть WhisperKit 0.9.4, модель Core ML `openai_whisper-large-v3_turbo` и токенизатор `openai/whisper-large-v3`. Установленное приложение читает их из своих ресурсов. Llama берётся из каталога локального Ollama. Если модели ещё нет, первый запуск настройки скачивает около 2 ГБ для `llama3.2:3b`. Для `llama3.2:1b` требуется около 1,3 ГБ. Русский входит в проверку Whisper. Русский язык отсутствует в списке официально поддерживаемых языков Llama 3.2, поэтому для русскоязычных итогов требуется отдельная проверка качества. [Модель Llama 3.2](https://ollama.com/library/llama3.2) · [Веса Whisper Core ML](https://huggingface.co/argmaxinc/whisperkit-coreml) · [Токенизатор Whisper](https://huggingface.co/openai/whisper-large-v3).

## Сборка и аудит

Из DMG скопируйте папку `Project` в каталог с правом записи. Для пересборки нужен Swift 6 с macOS SDK 15 или новее. SwiftPM при первой сборке получает зависимости версий из `Package.resolved`.

```zsh
swift test
ASR_SOURCE="/Volumes/A-notes/A-notes.app/Contents/Resources/OfflineASR/Model" \
TOKENIZER_SOURCE="/Volumes/A-notes/A-notes.app/Contents/Resources/OfflineASR/Hub/models/openai/whisper-large-v3" \
PACKAGE_HANDOFF=1 ./scripts/package-app.sh
```

Подставьте фактический путь к смонтированному образу. Если существующие модели лежат в стандартном локальном кэше WhisperKit, достаточно `PACKAGE_HANDOFF=1 ./scripts/package-app.sh`. Результаты появляются в `dist/handoff/`. Подробности и правила для Codex находятся в [AGENTS.md](AGENTS.md).

```zsh
./scripts/setup-local.sh "$HOME/Applications/A-notes.app" llama3.2:3b
./scripts/audit-handoff.sh "/path/to/A-notes-1.0.0-arm64-local-beta-handoff.dmg" llama3.2:3b
```

Настройка проверяет загрузку встроенного Whisper и запрос к Llama до сохранения профиля. Аудит монтирует DMG только для чтения, сверяет подпись, запускает Whisper с запретом сети, затем прогоняет синтетическое RU/EN-аудио через штатную очередь и открывает сохранённую библиотеку в новом процессе. Итог теста записи с микрофона и системного звука зависит от разрешений и проверяется отдельно.

## Подпись

Локальная сборка помечена `local-beta` и может блокироваться Gatekeeper на другом Mac. Для обычной внешней установки задайте `DEVELOPER_ID_APPLICATION` и `NOTARY_KEYCHAIN_PROFILE` при сборке. Статус текущей поставки см. в `SIGNING_STATUS.txt` внутри DMG и в отчёте аудита рядом с архивом.
