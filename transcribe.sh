#!/usr/bin/env bash
# transcribe.sh <audio-file>  →  plaintext transcript on stdout.
# Isolates speech-to-text behind one interface (proposal Decision #5). Default
# engine is a local whisper.cpp build; swap it (hosted API, another model) by
# pointing WHISPER_BIN/WHISPER_MODEL elsewhere — no daemon change.
set -euo pipefail
audio="${1:?usage: transcribe.sh <audio-file>}"
WHISPER_BIN="${WHISPER_BIN:-$HOME/whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/whisper.cpp/models/ggml-base.bin}"
[ -x "$WHISPER_BIN" ]  || { echo "transcribe: no whisper binary at $WHISPER_BIN (set WHISPER_BIN)" >&2; exit 3; }
[ -f "$WHISPER_MODEL" ] || { echo "transcribe: no model at $WHISPER_MODEL (set WHISPER_MODEL)" >&2; exit 3; }

wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
# Telegram voice notes are opus .oga; whisper wants 16 kHz mono PCM.
ffmpeg -nostdin -loglevel error -y -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
# -nt: no timestamps, plain text. -l auto: detect language (notes may be non-English).
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$wav" -nt -l auto 2>/dev/null | tr -s ' \t\n' ' ' | sed 's/^ *//; s/ *$//'
