#!/usr/bin/env bash
# tune-presets.sh — fit the chain's parameters to each noise type by measurement.
#
# This is NOT machine learning. There is no model and nothing is "trained" — it is
# a grid search over filter parameters, scored on objective measurements. The
# output is a set of preset values that are fitted to evidence instead of guessed.
#
# Method:
#   1. take a CLEAN speech file you supply
#   2. synthesise each noise type at a known SNR and mix it in
#   3. for every parameter combination, process both the noisy AND the clean file
#   4. score:  SNR gain  minus  a penalty for voice damage
#      - SNR       = speech-window RMS minus noise-window RMS
#      - damage    = per-band envelope distance between chain(noisy) and
#                    chain(clean); comparing against the same chain isolates the
#                    noise handling from the deliberate EQ
#   5. print the winning combination per noise type
#
# Usage:  ./tune-presets.sh clean-speech.wav [outdir]
#
# The clean file should be ~20 s, mostly speech, with one clear pause. Quality of
# the fit depends entirely on it being genuinely clean.
#
# Requires: ffmpeg

set -euo pipefail
CLEAN="${1:?usage: tune-presets.sh clean-speech.wav [outdir]}"
OUT="${2:-./tune-out}"
mkdir -p "$OUT"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }

SPEECH_WIN="${SPEECH_WIN:-0 9.5}"   # start dur — speech only
NOISE_WIN="${NOISE_WIN:-10.2 6}"    # start dur — pause only
DAMAGE_W="${DAMAGE_W:-6}"           # dB of SNR one dB of voice damage is worth

rms () { local ef="astats=metadata=1:reset=0,ametadata=print:file=-"
  [ -n "${4:-}" ] && ef="$4,$ef"
  ffmpeg -hide_banner -nostats -v error ${2:+-ss "$2"} ${3:+-t "$3"} -i "$1" \
    -af "$ef" -f null - 2>&1 | grep "^lavfi.astats.1.RMS_level=" | tail -1 | cut -d= -f2; }

# per-band envelope distance, immune to filter latency
damage () { local acc=0 x y
  for B in "100:300" "300:800" "800:2000" "2000:4000" "4000:8000" "8000:16000"; do
    x=$(rms "$1" ${SPEECH_WIN} "highpass=f=${B%%:*},lowpass=f=${B##*:}")
    y=$(rms "$2" ${SPEECH_WIN} "highpass=f=${B%%:*},lowpass=f=${B##*:}")
    acc=$(awk -v a="$acc" -v x="$x" -v y="$y" 'BEGIN{d=x-y; if(d<0)d=-d; print a+d}')
  done; awk -v a="$acc" 'BEGIN{printf "%.3f", a/6}'; }

# --- noise generators. Each models a real source's spectral signature ---------
mknoise () { # type outfile
  case "$1" in
    fan)   ffmpeg -y -v error -f lavfi -i "sine=frequency=50:duration=20" \
             -f lavfi -i "sine=frequency=100:duration=20" -f lavfi -i "sine=frequency=150:duration=20" \
             -f lavfi -i "anoisesrc=c=pink:r=48000:a=0.10:d=20" \
             -filter_complex "[0:a]volume=0.09[a];[1:a]volume=0.06[b];[2:a]volume=0.04[c];[3:a]lowpass=f=900,volume=1.6[d];[a][b][c][d]amix=inputs=4:duration=shortest:normalize=0,aformat=channel_layouts=mono[o]" \
             -map "[o]" -c:a pcm_s16le "$2" ;;
    hvac)  ffmpeg -y -v error -f lavfi -i "anoisesrc=c=brown:r=48000:a=0.28:d=20" \
             -ac 1 -af "lowpass=f=1200" -c:a pcm_s16le "$2" ;;
    hum)   ffmpeg -y -v error -f lavfi -i "sine=frequency=50:duration=20" \
             -f lavfi -i "sine=frequency=150:duration=20" -f lavfi -i "sine=frequency=250:duration=20" \
             -filter_complex "[0:a]volume=0.16[a];[1:a]volume=0.10[b];[2:a]volume=0.05[c];[a][b][c]amix=inputs=3:duration=shortest:normalize=0,aformat=channel_layouts=mono[o]" \
             -map "[o]" -c:a pcm_s16le "$2" ;;
    hiss)  ffmpeg -y -v error -f lavfi -i "anoisesrc=c=white:r=48000:a=0.035:d=20" \
             -ac 1 -c:a pcm_s16le "$2" ;;
    street) ffmpeg -y -v error -f lavfi -i "anoisesrc=c=brown:r=48000:a=0.34:d=20" \
             -ac 1 -af "lowpass=f=700,tremolo=f=0.15:d=0.6" -c:a pcm_s16le "$2" ;;
    # chair creaks / knocks: sparse broadband impulses, the non-stationary case
    impulse) ffmpeg -y -v error -f lavfi -i "anoisesrc=c=white:r=48000:a=0.5:d=20" \
             -ac 1 -af "tremolo=f=1.7:d=0.98,highpass=f=250" -c:a pcm_s16le "$2" ;;
    # background TV: speech-like babble, deliberately in the speech band
    tv)    ffmpeg -y -v error -f lavfi -i "anoisesrc=c=pink:r=48000:a=0.18:d=20" \
             -ac 1 -af "highpass=f=300,lowpass=f=3400,tremolo=f=3.5:d=0.85" -c:a pcm_s16le "$2" ;;
  esac; }

build_chain () { # hpf humhz nr margin ratio declick -> prints filtergraph
  local hpf="$1" humhz="$2" nr="$3" margin="$4" ratio="$5" declick="$6" pre="" h=1 f
  [ "$declick" = "1" ] && pre="adeclick=window=55:overlap=75:arorder=8:threshold=2,"
  pre="${pre}highpass=f=${hpf}"
  if [ "$humhz" != "0" ]; then
    h=1; while [ "$h" -le 5 ]; do f=$((humhz*h)); [ "$f" -lt 400 ] && \
      pre="${pre},equalizer=f=${f}:t=q:w=25:g=-24"; h=$((h+1)); done
  fi
  pre="${pre},afftdn=nr=${nr}:nf=${NF}"
  pre="${pre},equalizer=f=200:t=q:w=1.0:g=-3,equalizer=f=2800:t=q:w=1.0:g=6"
  pre="${pre},equalizer=f=5500:t=q:w=1.2:g=5,treble=g=4:f=9000"
  local post="acompressor=threshold=-20dB:ratio=3:attack=8:release=180:makeup=2"
  local mb="" mix="" i=0 th
  printf '[0:a]%s[mbin];[mbin]acrossover=split=200 500 1200 3000 6000' "$pre"
  while [ "$i" -lt 6 ]; do printf '[mb%s]' "$i"; i=$((i+1)); done; printf ';'
  i=0; while [ "$i" -lt 6 ]; do
    eval "th=\$(awk -v n=\"\$BAND_$i\" -v m=\"$margin\" 'BEGIN{printf \"%.0f\", n+m}')"
    printf '[mb%s]agate=threshold=%sdB:ratio=%s:attack=20:release=350:knee=8[mg%s];' "$i" "$th" "$ratio" "$i"
    mix="${mix}[mg${i}]"; i=$((i+1))
  done
  printf '%samix=inputs=6:normalize=0[mbout];[mbout]%s[out]' "$mix" "$post"; }

echo "clean reference: $CLEAN"
printf '%-9s %-42s %8s %8s %8s\n' TYPE "BEST PARAMS (hpf/hum/nr/margin/ratio/declick)" SNR DAMAGE SCORE

for T in fan hvac hum hiss street impulse tv; do
  mknoise "$T" "$OUT/n-$T.wav"
  ffmpeg -y -v error -i "$CLEAN" -i "$OUT/n-$T.wav" \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=shortest:normalize=0[o]" \
    -map "[o]" -ar 48000 -c:a pcm_s16le "$OUT/x-$T.wav"

  # calibrate once per noise type from the pause
  NF="$(rms "$OUT/x-$T.wav" ${NOISE_WIN})"
  NF="$(awk -v n="$NF" 'BEGIN{v=n; if(v>-20)v=-20; if(v<-80)v=-80; printf "%.0f", v}')"
  i=0; lo=0
  for hi in 200 500 1200 3000 6000 24000; do
    fl="highpass=f=${lo},lowpass=f=${hi}"; [ "$lo" = "0" ] && fl="lowpass=f=${hi}"
    v="$(rms "$OUT/x-$T.wav" ${NOISE_WIN} "$fl")"
    case "$v" in ""|*inf*) v="-70" ;; esac
    eval "BAND_$i=\"$v\""; lo="$hi"; i=$((i+1))
  done

  case "$T" in
    fan|hum) HUMS="50" ;;
    *)       HUMS="0"  ;;
  esac
  case "$T" in
    impulse) DECLICKS="0 1" ;;
    *)       DECLICKS="0"   ;;
  esac

  best=-999; bestp=""; bs=0; bd=0
  for hpf in 85 110 150; do
   for nr in 12 22 32; do
    for margin in 4 10; do
     for ratio in 2.5 4; do
      for dc in $DECLICKS; do
       g="$(build_chain "$hpf" "$HUMS" "$nr" "$margin" "$ratio" "$dc")"
       ffmpeg -y -v error -i "$OUT/x-$T.wav" -filter_complex "$g" -map "[out]" -c:a pcm_s16le "$OUT/o-n.wav" 2>/dev/null || continue
       ffmpeg -y -v error -i "$CLEAN"        -filter_complex "$g" -map "[out]" -c:a pcm_s16le "$OUT/o-c.wav" 2>/dev/null || continue
       sp="$(rms "$OUT/o-n.wav" ${SPEECH_WIN})"; nz="$(rms "$OUT/o-n.wav" ${NOISE_WIN})"
       if [ -z "$sp" ] || [ -z "$nz" ]; then continue; fi
       case "$sp$nz" in *inf*) continue ;; esac
       snr="$(awk -v a="$sp" -v b="$nz" 'BEGIN{printf "%.2f", a-b}')"
       dmg="$(damage "$OUT/o-n.wav" "$OUT/o-c.wav")"
       sc="$(awk -v s="$snr" -v d="$dmg" -v w="$DAMAGE_W" 'BEGIN{printf "%.2f", s-w*d}')"
       if awk -v a="$sc" -v b="$best" 'BEGIN{exit !(a>b)}'; then
         best="$sc"; bestp="hpf=$hpf hum=$HUMS nr=$nr margin=$margin ratio=$ratio declick=$dc"
         bs="$snr"; bd="$dmg"
       fi
      done; done; done; done; done
  printf '%-9s %-42s %8s %8s %8s\n' "$T" "$bestp" "$bs" "$bd" "$best"
done
