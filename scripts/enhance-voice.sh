#!/usr/bin/env bash
# enhance-voice.sh — rescue dull / quiet / noisy talk audio.
#
# For the case a video editor can't fix: a conference or room-mic recording where
# the voice is muffled and buried in broadband hiss. Applies a measured chain and
# muxes the result back with the ORIGINAL video stream copied bit-for-bit, so
# only the audio changes.
#
#   high-pass -> spectral denoise -> presence EQ
#             -> VOICE-BAND-KEYED expander -> compressor -> two-pass loudnorm
#
# The expander is the part that does the heavy lifting, and it is keyed on a
# band-passed copy of the signal (300-3400 Hz, the speech formants) rather than
# on the full band. Consumer "AI noise cancelling" mics (DJI, Hollyland) and
# Apple's Voice Isolation all describe the same core idea: identify the voice by
# its speech-band signature instead of suppressing everything under a threshold.
# Measured on a controlled benchmark (clean speech + noise at a known SNR):
#
#   noise across the whole band     full-band gate 45.4 dB -> voice-keyed 47.3 dB
#   noise outside the speech band   full-band gate 26.7 dB -> voice-keyed 42.6 dB
#   (rumble + hiss, the usual real case)                      +15.9 dB
#
# with no measurable difference in voice-shape damage. See BENCHMARK.md.
#
# Usage:
#   ./enhance-voice.sh input.mp4 [output.mp4]
#   TARGET_LUFS=-16 ./enhance-voice.sh input.mp4     # quieter target
#   NOCAL=1 ./enhance-voice.sh input.mp4             # skip auto noise calibration
#   VOICE_GATE=0 ./enhance-voice.sh input.mp4        # old full-band gate
#
# Audio-only inputs (wav/m4a/mp3/flac) are handled too — output is a wav.
#
# Requires: ffmpeg (brew install ffmpeg)

set -euo pipefail

IN="${1:?usage: enhance-voice.sh input.mp4 [output.mp4]}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

# --- tunables (env-overridable) ----------------------------------------------
TARGET_LUFS="${TARGET_LUFS:--14}"   # -14 social/YouTube; -16/-18 podcast feeds
TARGET_TP="${TARGET_TP:--1.5}"
TARGET_LRA="${TARGET_LRA:-9}"

HPF="${HPF:-85}"                    # rumble / wind / handling
DENOISE_NR="${DENOISE_NR:-12}"      # afftdn reduction dB; >20 starts eating the voice
MUD_HZ="${MUD_HZ:-200}";    MUD_G="${MUD_G:--3}"
PRES_HZ="${PRES_HZ:-2800}"; PRES_G="${PRES_G:-6}"
CLAR_HZ="${CLAR_HZ:-5500}"; CLAR_G="${CLAR_G:-5}"
AIR_HZ="${AIR_HZ:-9000}";   AIR_G="${AIR_G:-4}"   # AIR_G=0 if the mic has no real HF

VOICE_GATE="${VOICE_GATE:-1}"       # 1 = speech-band-keyed sidechain gate
SC_LO="${SC_LO:-300}"; SC_HI="${SC_HI:-3400}"     # speech formant band for the detector
GATE_RATIO="${GATE_RATIO:-2.5}"
COMP_THRESH="${COMP_THRESH:--20}"
COMP_RATIO="${COMP_RATIO:-3}"

rms_of () { # file start dur [prefilter]
  local ef="astats=metadata=1:reset=0,ametadata=print:file=-"
  [ -n "${4:-}" ] && ef="$4,$ef"
  ffmpeg -hide_banner -nostats -v error ${2:+-ss "$2"} ${3:+-t "$3"} -i "$1" \
    -af "$ef" -f null - 2>&1 | grep -m1 "^lavfi.astats.1.RMS_level=" | cut -d= -f2
}

# --- auto-calibration: read the actual noise floor out of a speech pause ------
# Everything downstream keys off this. A guessed threshold below the real floor
# means the expander never closes; above the speech level it chews up words.
NOISE_RMS=""
if [ "${NOCAL:-0}" != "1" ]; then
  echo "==> calibrating from a measured pause"
  PAUSE="$(ffmpeg -hide_banner -nostats -v info -i "$IN" \
            -af "silencedetect=noise=-38dB:d=0.4" -f null - 2>&1 \
          | grep -E "silence_(start|duration)" | paste - - \
          | sed 's/.*silence_start: //; s/\[Parsed.*silence_duration: / /' \
          | sort -k2 -g -r | head -1)"
  PS="$(printf '%s' "$PAUSE" | awk '{print $1}')"
  PD="$(printf '%s' "$PAUSE" | awk '{print $2}')"
  if [ -n "$PS" ] && [ -n "$PD" ]; then
    # step inside the pause so the measurement isn't polluted by word tails
    MS="$(awk -v s="$PS" 'BEGIN{printf "%.3f", s+0.15}')"
    MD="$(awk -v d="$PD" 'BEGIN{d=d-0.3; if(d>2)d=2; if(d<0.2)d=0.2; printf "%.3f", d}')"
    CAND="$(rms_of "$IN" "$MS" "$MD")"
    # a lead-in of digital silence reads -inf and is useless as a noise profile
    case "$CAND" in ""|*inf*) CAND="" ;; esac
    [ -n "$CAND" ] && { NOISE_RMS="$CAND"; echo "    noise floor ${NOISE_RMS} dB (pause at ${MS}s)"; }
  fi
  [ -z "$NOISE_RMS" ] && echo "    no usable pause found — falling back to defaults"
fi

if [ -n "$NOISE_RMS" ]; then
  # denoise floor at the measured noise; expander threshold a touch above it
  DENOISE_NF="${DENOISE_NF:-$(awk -v n="$NOISE_RMS" 'BEGIN{printf "%.0f", n}')}"
  GATE_THRESH="${GATE_THRESH:-$(awk -v n="$NOISE_RMS" 'BEGIN{printf "%.0f", n+5}')}"
else
  DENOISE_NF="${DENOISE_NF:--35}"   # -35 is the useful limit; -40 with high nr
  GATE_THRESH="${GATE_THRESH:--50}" # can strip ~27 dB of real highs
fi
echo "    afftdn nf=${DENOISE_NF}  expander threshold=${GATE_THRESH} dB"

PRE="highpass=f=${HPF}"
PRE="${PRE},afftdn=nr=${DENOISE_NR}:nf=${DENOISE_NF}"
PRE="${PRE},equalizer=f=${MUD_HZ}:t=q:w=1.0:g=${MUD_G}"
PRE="${PRE},equalizer=f=${PRES_HZ}:t=q:w=1.0:g=${PRES_G}"
PRE="${PRE},equalizer=f=${CLAR_HZ}:t=q:w=1.2:g=${CLAR_G}"
[ "$AIR_G" != "0" ] && PRE="${PRE},treble=g=${AIR_G}:f=${AIR_HZ}"
GATE_ARGS="ratio=${GATE_RATIO}:attack=20:release=350:knee=8"
POST="acompressor=threshold=${COMP_THRESH}dB:ratio=${COMP_RATIO}:attack=8:release=180:makeup=2"

# Build the graph. The expander goes AFTER the EQ (so it keys on the boosted
# signal) and BEFORE the compressor (so the compressor can't re-lift what the
# expander just pushed down).
graph () { # $1 = extra tail filter (e.g. loudnorm), may be empty
  local tail="${1:-}"
  local post="$POST"; [ -n "$tail" ] && post="${POST},${tail}"
  if [ "$VOICE_GATE" = "1" ]; then
    printf '[0:a]%s[m];[m]asplit=2[main][det];[det]highpass=f=%s,lowpass=f=%s[sc];[main][sc]sidechaingate=threshold=%sdB:%s[g];[g]%s[out]' \
      "$PRE" "$SC_LO" "$SC_HI" "$GATE_THRESH" "$GATE_ARGS" "$post"
  else
    printf '[0:a]%s,agate=threshold=%sdB:%s,%s[out]' \
      "$PRE" "$GATE_THRESH" "$GATE_ARGS" "$post"
  fi
}

case "$(printf '%s' "${IN##*.}" | tr '[:upper:]' '[:lower:]')" in
  wav|m4a|mp3|aac|flac|aif|aiff) AUDIO_ONLY=1 ;;
  *) AUDIO_ONLY=0 ;;
esac
if [ "$AUDIO_ONLY" = 1 ]; then OUT="${2:-${IN%.*}-enhanced.wav}"
else OUT="${2:-${IN%.*}-enhanced.mp4}"; fi
[ "$OUT" = "$IN" ] && { echo "refusing to overwrite the input in place" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> pass 1/3  measuring loudness"
STATS="$(ffmpeg -hide_banner -nostats -i "$IN" -filter_complex \
  "$(graph "loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json")" \
  -map "[out]" -f null - 2>&1 | sed -n '/^{/,/^}/p')"
[ -n "$STATS" ] || { echo "loudnorm produced no measurement" >&2; exit 1; }

jget () { printf '%s' "$STATS" | grep "\"$1\"" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'; }
M_I="$(jget input_i)";        M_TP="$(jget input_tp)"
M_LRA="$(jget input_lra)";    M_TH="$(jget input_thresh)"
M_OFF="$(jget target_offset)"
[ -n "$M_I" ] && [ -n "$M_TP" ] && [ -n "$M_TH" ] || {
  echo "could not parse loudnorm stats" >&2; printf '%s\n' "$STATS" >&2; exit 1; }
echo "    measured I=${M_I} TP=${M_TP} LRA=${M_LRA}"

# linear=true => one constant gain for the whole file. Without it loudnorm runs
# dynamically and can audibly pump on speech.
LN="loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=${TARGET_LRA}"
LN="${LN}:measured_I=${M_I}:measured_TP=${M_TP}:measured_LRA=${M_LRA}"
LN="${LN}:measured_thresh=${M_TH}:offset=${M_OFF}:linear=true"

echo "==> pass 2/3  rendering audio"
ffmpeg -y -hide_banner -nostats -v warning -i "$IN" \
  -filter_complex "$(graph "$LN")" -map "[out]" -ar 48000 -c:a pcm_s16le "$TMP/audio.wav"

if [ "$AUDIO_ONLY" = 1 ]; then
  echo "==> pass 3/3  writing $OUT"; cp "$TMP/audio.wav" "$OUT"
else
  echo "==> pass 3/3  muxing with original video (stream copy)"
  ffmpeg -y -hide_banner -nostats -v warning -i "$IN" -i "$TMP/audio.wav" \
    -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 192k -movflags +faststart "$OUT"
  echo "    duration  in=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")s" \
       " out=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s"
fi

echo "==> done: $OUT"
echo "    verify with: scripts/audio-report.sh \"$OUT\""
