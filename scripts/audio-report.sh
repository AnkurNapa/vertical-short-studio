#!/usr/bin/env bash
# audio-report.sh — measure audio instead of guessing at it.
#
# Prints the numbers that actually decide voice-track decisions:
#   integrated loudness, true peak, spectral rolloff (dullness), and — if you
#   point it at a silent pause — the speech-to-noise ratio.
#
# Usage:
#   ./audio-report.sh file.mp4
#   ./audio-report.sh file.mp4 --pause 9.6 0.7     # SNR using pause at 9.6s for 0.7s
#   ./audio-report.sh file.mp4 --find-pauses       # locate room-tone pauses to use above
#
# Requires: ffmpeg

set -euo pipefail
F="${1:?usage: audio-report.sh file [--pause START DUR | --find-pauses]}"
[ -f "$F" ] || { echo "no such file: $F" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
MODE="${2:-}"

rms () { # file start dur [prefilter]
  local ef="astats=metadata=1:reset=0,ametadata=print:file=-"
  [ -n "${4:-}" ] && ef="$4,$ef"
  ffmpeg -hide_banner -nostats -v error ${2:+-ss "$2"} ${3:+-t "$3"} -i "$1" \
    -af "$ef" -f null - 2>&1 | grep "^lavfi.astats.1.RMS_level=" | tail -1 | cut -d= -f2
}

if [ "$MODE" = "--find-pauses" ]; then
  echo "room-tone pauses (longest first) — pick one well inside speech, not the file's lead-in:"
  # A file's opening is often digital silence (all zeros), which is useless as a
  # noise profile. Real room tone lives in the gaps between sentences.
  ffmpeg -hide_banner -nostats -v info -i "$F" -af "silencedetect=noise=-38dB:d=0.35" \
    -f null - 2>&1 | grep -E "silence_(start|duration)" | paste - - \
    | sed 's/.*silence_start: //; s/\[Parsed.*silence_duration: /  dur=/' \
    | sort -t= -k2 -g -r | head -8
  echo
  echo "then: $0 \"$F\" --pause <start+0.1> <dur-0.2>"
  exit 0
fi

EB="$(ffmpeg -hide_banner -nostats -i "$F" -af ebur128=peak=true -f null - 2>&1)"
I="$(printf '%s' "$EB"  | grep -A4 "Integrated loudness" | grep -m1 "I:"   | awk '{print $2}')"
LRA="$(printf '%s' "$EB" | grep -A4 "Loudness range"     | grep -m1 "LRA:" | awk '{print $2}')"
TP="$(printf '%s' "$EB"  | grep -m1 "Peak:" | awk '{print $2}')"

# Rolloff proxy: how much energy survives a 3 kHz high-pass, relative to full band.
# A dull room mic sits near -19 dB or lower; a clear voice is well above it.
FULL="$(rms "$F" "" "")"
HF="$(rms "$F" "" "" "highpass=f=3000")"
BRIGHT="$(awk -v a="$HF" -v b="$FULL" 'BEGIN{printf "%.2f", a-b}')"

printf '\n%s\n' "$(basename "$F")"
printf '  integrated   %8s LUFS   (social target -14, podcast -16/-18)\n' "$I"
printf '  true peak    %8s dBFS   (keep at or under -1.0)\n' "$TP"
printf '  loudness rng %8s LU\n' "$LRA"
printf '  brightness   %8s dB     (HF>3kHz vs full band; under about -25 reads muffled)\n' "$BRIGHT"

if [ "$MODE" = "--pause" ]; then
  PS="${3:?--pause needs START}"; PD="${4:?--pause needs DUR}"
  SP="$(rms "$F" 0 "$PS")"          # speech before the pause
  NZ="$(rms "$F" "$PS" "$PD")"      # the pause itself = residual noise
  SNR="$(awk -v a="$SP" -v b="$NZ" 'BEGIN{printf "%.2f", a-b}')"
  printf '  speech RMS   %8s dB\n' "$SP"
  printf '  noise RMS    %8s dB     (measured in the pause at %ss)\n' "$NZ" "$PS"
  printf '  SNR          %8s dB     (raw room mic ~15; after enhance-voice.sh ~35)\n' "$SNR"
fi
echo
