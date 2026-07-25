#!/usr/bin/env bash
# music-bed-gain.sh — how loud should the music bed actually be?
#
# Guessing this is why so many talking-head videos ship with a bed that is either
# inaudible or fighting the voice. It is arithmetic, not taste:
#
#     volumeDb = (voice_LUFS - duck_LU) - music_native_LUFS
#
# duck_LU is how far under the voice the bed should sit. 19 LU is a good default
# for spoken-word shorts: clearly present, never competing.
#
# Usage:
#   ./music-bed-gain.sh music.m4a                 # assumes voice -14 LUFS, duck 19 LU
#   ./music-bed-gain.sh music.m4a -16             # voice is -16 LUFS
#   ./music-bed-gain.sh music.m4a -14 22          # duck it 22 LU instead
#
# Requires: ffmpeg

set -euo pipefail
M="${1:?usage: music-bed-gain.sh music-file [voice_LUFS] [duck_LU]}"
[ -f "$M" ] || { echo "no such file: $M" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

VOICE="${2:--14}"
DUCK="${3:-19}"

NATIVE="$(ffmpeg -hide_banner -nostats -i "$M" -af ebur128 -f null - 2>&1 \
          | grep -A4 "Integrated loudness" | grep -m1 "I:" | awk '{print $2}')"
[ -n "$NATIVE" ] || { echo "could not measure $M" >&2; exit 1; }

GAIN="$(awk -v v="$VOICE" -v d="$DUCK" -v n="$NATIVE" 'BEGIN{printf "%.1f", (v-d)-n}')"
BEDLVL="$(awk -v v="$VOICE" -v d="$DUCK" 'BEGIN{printf "%.1f", v-d}')"

printf '\n%s\n' "$(basename "$M")"
printf '  music native     %8s LUFS\n' "$NATIVE"
printf '  voice target     %8s LUFS\n' "$VOICE"
printf '  duck under voice %8s LU\n'   "$DUCK"
printf '  ------------------------------\n'
printf '  set clip volume  %8s dB   -> bed lands at %s LUFS\n\n' "$GAIN" "$BEDLVL"
