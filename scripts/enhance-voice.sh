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
#   PRESET=fan ./enhance-voice.sh input.mp4          # ceiling fan / hvac / hum / appliance / street / tv
#   ALGO=gate ./enhance-voice.sh input.mp4           # single-band instead of multiband
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

# --- noise presets -----------------------------------------------------------
# PRESET tunes the chain for a noise type. What matters is whether the noise is
# STATIONARY (steady, so it can be profiled and subtracted even under speech) and
# whether it sits OUTSIDE the 300-3400 Hz speech band (so it can be removed
# without touching the voice). Presets are starting points; auto-calibration
# still measures your actual noise floor on top.
#
#   room      (default) general room tone / hiss
#   fan       ceiling or pedestal fan: motor hum + blade whoosh
#   hvac      air-conditioner / extractor / server hum
#   hum       electrical buzz only (mains harmonics), voice otherwise clean
#   appliance mixer, grinder, blender, drill — loud broadband bursts
#   street    traffic rumble through a window
#   tv        TV or radio talking in the background
#
PRESET="${PRESET:-room}"
case "$PRESET" in
  fan)       : "${HPF:=110}" "${HUM_HZ:=50}" "${DENOISE_NR:=18}" "${GATE_RATIO:=3}" ;;
  hvac)      : "${HPF:=100}" "${HUM_HZ:=0}"  "${DENOISE_NR:=18}" "${GATE_RATIO:=3}" ;;
  hum)       : "${HPF:=70}"  "${HUM_HZ:=50}" "${DENOISE_NR:=6}"  "${GATE_RATIO:=2}" ;;
  appliance) : "${HPF:=120}" "${HUM_HZ:=0}"  "${DENOISE_NR:=24}" "${GATE_RATIO:=3}" ;;
  street)    : "${HPF:=120}" "${HUM_HZ:=0}"  "${DENOISE_NR:=20}" "${GATE_RATIO:=3}" ;;
  tv)        : "${HPF:=90}"  "${HUM_HZ:=0}"  "${DENOISE_NR:=10}" "${GATE_RATIO:=2}" ;;
  room)      : ;;
  *) echo "unknown PRESET '$PRESET' (room|fan|hvac|hum|appliance|street|tv)" >&2; exit 1 ;;
esac

# --- tunables (env-overridable) ----------------------------------------------
HUM_HZ="${HUM_HZ:-0}"               # mains frequency: 50 (EU/IN/AU), 60 (US/JP), 0 = off
HUM_HARMONICS="${HUM_HARMONICS:-4}" # notch the fundamental + this many harmonics
TARGET_LUFS="${TARGET_LUFS:--14}"   # -14 social/YouTube; -16/-18 podcast feeds
TARGET_TP="${TARGET_TP:--1.5}"
TARGET_LRA="${TARGET_LRA:-9}"

HPF="${HPF:-85}"                    # rumble / wind / handling
DENOISE_NR="${DENOISE_NR:-12}"      # afftdn reduction dB; >20 starts eating the voice
MUD_HZ="${MUD_HZ:-200}";    MUD_G="${MUD_G:--3}"
PRES_HZ="${PRES_HZ:-2800}"; PRES_G="${PRES_G:-6}"
CLAR_HZ="${CLAR_HZ:-5500}"; CLAR_G="${CLAR_G:-5}"
AIR_HZ="${AIR_HZ:-9000}";   AIR_G="${AIR_G:-4}"   # AIR_G=0 if the mic has no real HF

ALGO="${ALGO:-multiband}"           # gate = speech-band-keyed expander (single band)
                                    # multiband = per-band expander, thresholds from
                                    #   a measured noise profile (spectral gating)
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

# --- multiband spectral gating ------------------------------------------------
# Classical spectral subtraction (Boll 1979) suppresses each frequency bin against
# a noise profile measured from a silent passage; Audacity's Noise Reduction and
# the `noisereduce` library are the same idea. A single full-band expander is the
# degenerate one-band case: one threshold for the whole spectrum, so a band where
# noise dominates and a band where the voice dominates get treated alike.
#
# Here the signal is split across crossovers and each band gets its OWN expander,
# with its threshold taken from that band's measured noise level in the
# calibration pause. Bands where the fan or hiss dominates close hard; bands
# carrying the voice stay open.
MB_XOVERS="${MB_XOVERS:-200 500 1200 3000 6000}"
MB_MARGIN="${MB_MARGIN:-6}"     # dB above each band's measured noise floor

mb_graph () {  # emits: split -> per-band expander -> remix, reading [mbin], writing [mbout]
  local i=0 n=0 legs="" mix=""
  set -- $MB_XOVERS
  n=$(( $# + 1 ))
  printf '[mbin]acrossover=split=%s' "$MB_XOVERS"
  i=0; while [ "$i" -lt "$n" ]; do printf '[mb%s]' "$i"; i=$((i+1)); done
  printf ';'
  i=0
  while [ "$i" -lt "$n" ]; do
    eval "th=\${MB_TH_$i:--50}"
    printf '[mb%s]agate=threshold=%sdB:ratio=%s:attack=20:release=350:knee=8[mg%s];' \
      "$i" "$th" "$GATE_RATIO" "$i"
    mix="${mix}[mg${i}]"
    i=$((i+1))
  done
  printf '%samix=inputs=%s:normalize=0[mbout]' "$mix" "$n"
}

# measure the noise floor per band inside the calibration pause
mb_calibrate () {
  local i=0 lo=0 hi bands
  bands="$MB_XOVERS"
  set -- $bands
  local edges="$* 24000"
  for hi in $edges; do
    local f="highpass=f=${lo},lowpass=f=${hi}"
    [ "$lo" = "0" ] && f="lowpass=f=${hi}"
    local v; v="$(rms_of "$IN" "$MS" "$MD" "$f" || true)"
    case "$v" in ""|*inf*) v="-60" ;; esac
    eval "MB_TH_$i=\$(awk -v n=\"\$v\" -v m=\"\$MB_MARGIN\" 'BEGIN{printf \"%.0f\", n+m}')"
    eval "echo \"      band $i (${lo}-${hi} Hz): noise \$v dB -> threshold \$MB_TH_$i dB\""
    lo="$hi"; i=$((i+1))
  done
}


# --- auto-calibration: read the actual noise floor out of a speech pause ------
# Everything downstream keys off this. A guessed threshold below the real floor
# means the expander never closes; above the speech level it chews up words.
NOISE_RMS=""
if [ "${NOCAL:-0}" != "1" ]; then
  echo "==> calibrating from a measured pause"
  # Sweep the detector threshold downward-to-upward: a quiet room has pauses
  # under -38 dB, but a running fan or air-con can sit at -25 dB, in which case
  # a fixed -38 dB finds nothing and we would silently fall back to defaults on
  # exactly the files that need calibration most.
  PS=""; PD=""
  for TH in -45 -38 -32 -27 -22; do
    PAUSE="$(ffmpeg -hide_banner -nostats -v info -i "$IN" \
              -af "silencedetect=noise=${TH}dB:d=0.4" -f null - 2>&1 \
            | grep -E "silence_(start|duration)" | paste - - \
            | sed 's/.*silence_start: //; s/\[Parsed.*silence_duration: / /' \
            | sort -k2 -g -r | head -1 || true)"
    PS="$(printf '%s' "$PAUSE" | awk '{print $1}' || true)"
    PD="$(printf '%s' "$PAUSE" | awk '{print $2}' || true)"
    if [ -n "$PS" ] && [ -n "$PD" ]; then
      echo "    found pause via ${TH} dB detector"
      break
    fi
  done
  if [ -n "$PS" ] && [ -n "$PD" ]; then
    # step inside the pause so the measurement isn't polluted by word tails
    MS="$(awk -v s="$PS" 'BEGIN{printf "%.3f", s+0.15}')"
    MD="$(awk -v d="$PD" 'BEGIN{d=d-0.3; if(d>2)d=2; if(d<0.2)d=0.2; printf "%.3f", d}')"
    CAND="$(rms_of "$IN" "$MS" "$MD")"
    # a lead-in of digital silence reads -inf and is useless as a noise profile
    case "$CAND" in ""|*inf*) CAND="" ;; esac
    [ -n "$CAND" ] && { NOISE_RMS="$CAND"; echo "    noise floor ${NOISE_RMS} dB (pause at ${MS}s)"; }
    if [ "$ALGO" = "multiband" ] && [ -n "$NOISE_RMS" ]; then
      echo "    per-band noise profile:"
      mb_calibrate
    fi
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
# Mains hum is tonal, so narrow notches remove it almost perfectly while a
# broadband denoiser would only smear it. Harmonics matter as much as the
# fundamental — a 50 Hz buzz is usually audible mostly at 100/150/200 Hz.
if [ "${HUM_HZ}" != "0" ]; then
  h=1
  while [ "$h" -le "$((HUM_HARMONICS + 1))" ]; do
    f=$((HUM_HZ * h))
    [ "$f" -lt 400 ] && PRE="${PRE},equalizer=f=${f}:t=q:w=25:g=-24"
    h=$((h + 1))
  done
  echo "    notching ${HUM_HZ} Hz hum + harmonics"
fi
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
  # multiband needs a per-band noise profile; without calibration its thresholds
  # would be guesses, so fall back to the single-band expander instead.
  if [ "$ALGO" = "multiband" ] && [ -z "${MB_TH_0:-}" ]; then
    ALGO="gate"
    echo "    (no per-band profile — using single-band expander)" >&2
  fi
  if [ "$ALGO" = "multiband" ]; then
    printf '[0:a]%s[mbin];%s;[mbout]%s[out]' "$PRE" "$(mb_graph)" "$post"
  elif [ "$VOICE_GATE" = "1" ]; then
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
