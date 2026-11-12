#!/bin/zsh
# Run diagnostics on the app mounted from the delivered image.
set -euo pipefail
IMAGE=${1:?Usage: audit-handoff.sh /path/to/handoff.dmg [llama3.2:3b]}
IMAGE="${IMAGE:A}"
MODEL=${2:-llama3.2:3b}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/a-notes-audit.XXXXXX")
MOUNT="$WORK/mounted"
mkdir "$MOUNT" "$WORK/home"
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach "$MOUNT" >/dev/null || { print -u2 "Could not detach $MOUNT"; return; }
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

(cd "${IMAGE:h}" && shasum -a 256 -c "${IMAGE:t}.sha256")
hdiutil verify "$IMAGE"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$IMAGE" >/dev/null
mounted=1
APP="$MOUNT/A-notes.app"
BIN="$APP/Contents/MacOS/A-notes"
for item in README.md AGENTS.md CODEX_START_PROMPT.md Project/Package.resolved Project/scripts/setup-local.sh Project/scripts/package-app.sh; do
  [[ -f "$MOUNT/$item" ]]
done
architecture=$(file "$BIN")
print "$architecture"
[[ "$architecture" == *arm64* ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == 15.0 ]]
codesign --verify --deep --strict "$APP"
if spctl --assess --type execute --verbose=2 "$APP"; then
  print 'Gatekeeper accepted this app on the test Mac.'
else
  print 'Gatekeeper rejected this app on the test Mac.'
fi
CFFIXED_USER_HOME="$WORK/home" /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' "$BIN" --check-bundled-asr
FIXTURES="$MOUNT/Project/assets/audit"
"$BIN" --audit-processing "$WORK/library" "$MODEL" "$FIXTURES/library-en.caf" "$FIXTURES/library-ru.caf"
"$BIN" --audit-reopen "$WORK/library"
codesign --verify --deep --strict "$APP"
print 'PASS: image, signature and packaged processing audit'
