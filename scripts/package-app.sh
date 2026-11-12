#!/bin/zsh
# Apple Silicon distribution. Uses a separate output directory.
set -eu
cd "${0:A:h:h}"
if [[ ${PACKAGE_HANDOFF:-0} == 1 ]]; then
  export APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-$PWD/dist/handoff}"
  export APP_BUILD_VERSION="${APP_BUILD_VERSION:-20261112.1}"
else
  export APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-$PWD/dist/release}"
fi
mkdir -p "$APP_OUTPUT_DIR"
export APP_OUTPUT_DIR="$(cd "$APP_OUTPUT_DIR" && pwd)"
export BUILD_CONFIGURATION=release
export INCLUDE_OFFLINE_ASR=1
"$PWD/scripts/build-app.sh"
PAYLOAD=$(mktemp -d "$APP_OUTPUT_DIR/.dmg-XXXXXX")
IMAGE="$APP_OUTPUT_DIR/.${PAYLOAD:t}.dmg"
trap 'rm -rf "$PAYLOAD"; rm -f "$IMAGE"' EXIT
cp -cR "$APP_OUTPUT_DIR/A-notes.app" "$PAYLOAD/A-notes.app"
ln -s /Applications "$PAYLOAD/Applications"
cp docs/GETTING_STARTED.md docs/CODEX_SETUP.md "$PAYLOAD/"
if [[ ${PACKAGE_HANDOFF:-0} == 1 ]]; then
  PROJECT="$PAYLOAD/Project"
  mkdir -p "$PROJECT/docs" "$PROJECT/assets/branding"
  cp README.md AGENTS.md CODEX_START_PROMPT.md "$PAYLOAD/"
  cp README.md AGENTS.md CODEX_START_PROMPT.md Package.swift Package.resolved .gitignore "$PROJECT/"
  cp -R Sources Tests scripts "$PROJECT/"
  cp assets/branding/a-notes-logo.png assets/branding/README.md "$PROJECT/assets/branding/"
  cp -R assets/audit "$PROJECT/assets/"
  cp docs/GETTING_STARTED.md docs/CODEX_SETUP.md docs/OBSIDIAN_STORAGE.md docs/WHISPER_LICENSE.txt "$PROJECT/docs/"
  ln -s Project/docs "$PAYLOAD/docs"
fi
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
  NAME=A-notes-1.0.0-arm64
else
  NAME=A-notes-1.0.0-arm64-local-beta
  print 'Локально подписанная бета без нотарификации Apple. Gatekeeper другого Mac может блокировать приложение. Для обычной внешней установки нужны Developer ID и нотарификация.' > "$PAYLOAD/SIGNING_STATUS.txt"
fi
if [[ ${PACKAGE_HANDOFF:-0} == 1 ]]; then
  NAME="${NAME}-handoff"
fi
hdiutil create -volname A-notes -srcfolder "$PAYLOAD" -format UDZO "$IMAGE"
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$IMAGE"
  if [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]]; then
    xcrun notarytool submit "$IMAGE" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$IMAGE"
    xcrun stapler validate "$IMAGE"
  else
    print -u2 'Developer ID build created; NOTARY_KEYCHAIN_PROFILE missing, notarization NOT completed.'
  fi
fi
mv -f "$IMAGE" "$APP_OUTPUT_DIR/$NAME.dmg"
(cd "$APP_OUTPUT_DIR" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
print "$APP_OUTPUT_DIR/$NAME.dmg"
