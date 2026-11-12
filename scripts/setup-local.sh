#!/bin/zsh
set -euo pipefail
APP=${1:?Usage: setup-local.sh /path/to/A-notes.app [llama3.2:3b]}
MODEL=${2:-llama3.2:3b}
BIN="$APP/Contents/MacOS/A-notes"
SERVER=http://127.0.0.1:11434
[[ -x "$BIN" ]] || { print -u2 "A-notes executable missing: $BIN"; exit 1; }
codesign --verify --deep --strict "$APP"
case "$MODEL" in
  llama3.2:3b|llama3.2:1b) ;;
  *) print -u2 "Choose llama3.2:3b or llama3.2:1b"; exit 2 ;;
esac

ollama_api() { /usr/bin/curl --noproxy '*' -fsS --max-time 5 "$@"; }
OLLAMA=$(command -v ollama || true)
if [[ -z "$OLLAMA" ]]; then
  for candidate in "$HOME/Applications/Ollama.app/Contents/Resources/ollama" /Applications/Ollama.app/Contents/Resources/ollama; do
    if [[ -x "$candidate" ]]; then OLLAMA="$candidate"; break; fi
  done
fi
if ! ollama_api "$SERVER/api/version" >/dev/null 2>&1; then
  [[ -n "$OLLAMA" ]] || { print -u2 "Ollama is missing. Install from https://ollama.com/download/mac"; exit 1; }
  LOG_DIR="$HOME/Library/Logs/A-notes"
  mkdir -p "$LOG_DIR"
  OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 nohup "$OLLAMA" serve </dev/null >>"$LOG_DIR/ollama.log" 2>&1 &
  disown
  for attempt in {1..30}; do
    if ollama_api "$SERVER/api/version" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  ollama_api "$SERVER/api/version" >/dev/null
fi

show_model() {
  ollama_api -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL\"}" "$SERVER/api/show"
}
if ! metadata=$(show_model 2>/dev/null); then
  [[ -n "$OLLAMA" ]] || { print -u2 "Ollama CLI is required for the model pull"; exit 1; }
  OLLAMA_HOST=127.0.0.1:11434 "$OLLAMA" pull "$MODEL"
  metadata=$(show_model)
fi
family=$(plutil -extract details.family raw -o - -- - <<<"$metadata")
[[ "$family" == llama ]] || { print -u2 "Unexpected Ollama model family: $family"; exit 1; }
for key in remote_host remote_model; do
  if [[ -n $(plutil -extract "$key" raw -o - -- - <<<"$metadata" 2>/dev/null || true) ]]; then
    print -u2 "Ollama reports a remote model: $MODEL"
    exit 1
  fi
done
"$BIN" --check-bundled-asr
"$BIN" --configure-local-model --provider ollama --server "$SERVER" --model "$MODEL" --verify --use-bundled-asr
"$BIN" --check-local-model
