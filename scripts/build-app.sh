#!/bin/zsh
set -eu
cd "${0:A:h:h}"
"$PWD/scripts/build-icon.sh"
BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-debug}
APP_BUILD_VERSION=${APP_BUILD_VERSION:-20261105.1}
APP_OUTPUT_DIR=${APP_OUTPUT_DIR:-$PWD/dist}
swift build -c "$BUILD_CONFIGURATION"
BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)
mkdir -p "$APP_OUTPUT_DIR"
STAGING=$(mktemp -d "$APP_OUTPUT_DIR/.build-XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/A-notes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PWD/assets/branding/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/AntonNotes" "$APP/Contents/MacOS/A-notes"
cp "$PWD/docs/CODEX_SETUP.md" "$PWD/docs/GETTING_STARTED.md" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$PWD/.build/checkouts/WhisperKit/LICENSE" "$APP/Contents/Resources/Licenses/WhisperKit.txt"
cp "$PWD/.build/checkouts/swift-transformers/LICENSE" "$APP/Contents/Resources/Licenses/swift-transformers.txt"
cp "$PWD/.build/checkouts/swift-argument-parser/LICENSE.txt" "$APP/Contents/Resources/Licenses/swift-argument-parser.txt"
cp "$PWD/docs/WHISPER_LICENSE.txt" "$APP/Contents/Resources/Licenses/Whisper.txt"
if [[ ${INCLUDE_OFFLINE_ASR:-0} == 1 ]]; then
  ASR_SOURCE=${ASR_SOURCE:-$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo}
  TOKENIZER_SOURCE=${TOKENIZER_SOURCE:-$HOME/Documents/huggingface/models/openai/whisper-large-v3}
  for model in AudioEncoder TextDecoder MelSpectrogram; do
    [[ -d "$ASR_SOURCE/$model.mlmodelc" ]] || { print -u2 "Missing offline ASR asset: $ASR_SOURCE/$model.mlmodelc"; exit 1; }
  done
  for json in tokenizer.json tokenizer_config.json; do
    [[ -f "$TOKENIZER_SOURCE/$json" ]] || { print -u2 "Missing tokenizer asset: $TOKENIZER_SOURCE/$json"; exit 1; }
  done
  mkdir -p "$APP/Contents/Resources/OfflineASR/Hub/models/openai"
  cp -cR "$ASR_SOURCE" "$APP/Contents/Resources/OfflineASR/Model"
  cp -cR "$TOKENIZER_SOURCE" "$APP/Contents/Resources/OfflineASR/Hub/models/openai/whisper-large-v3"
  chmod -R a+rX "$APP/Contents/Resources/OfflineASR"
fi
for resource in "$BIN_DIR/"*.bundle(N); do
  cp -R "$resource" "$APP/Contents/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>personal.anton.notes</string>
<key>CFBundleName</key><string>A-notes</string>
<key>CFBundleDisplayName</key><string>A-notes</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>A-notes</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>20261105.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Запись вашего голоса во время выбранного звонка.</string>
<key>NSAudioCaptureUsageDescription</key><string>Запись звука собеседников для локального транскрипта.</string>
<key>NSScreenCaptureUsageDescription</key><string>ScreenCaptureKit используется для получения системного аудио. Видео не сохраняется.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$APP/Contents/Info.plist"
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
  for resource in "$APP/Contents/"*.bundle(N); do
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$resource"
  done
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$APP"
  codesign --verify --deep --strict "$APP"
else
  "$PWD/scripts/sign-local.sh" "$APP"
fi
mkdir -p "$APP_OUTPUT_DIR/.previous"
for existing in "$APP_OUTPUT_DIR/A-notes.app" "$APP_OUTPUT_DIR/AntonNotes.app"; do
  if [[ -d "$existing" ]]; then
    mv "$existing" "$APP_OUTPUT_DIR/.previous/${existing:t}-$(date +%Y%m%d-%H%M%S).bak"
  fi
done
mv "$APP" "$APP_OUTPUT_DIR/A-notes.app"
print "$APP_OUTPUT_DIR/A-notes.app"
