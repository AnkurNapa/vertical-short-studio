# vertical-short-studio

Tools for turning a long talk or screen recording into vertical Shorts — and for
fixing the audio when the source is a dull, quiet, noisy room mic.

Two independent pieces. Take either one:

- **`scripts/`** — standalone ffmpeg tools. No editor required, work on any video or audio file.
- **`skills/yt-short-flow/`** — a [Claude Code](https://claude.com/claude-code) skill that drives
  [Palmier Pro](https://palmier.io) via MCP to build the whole Short: 9:16 layout, blurred fill
  background, header/footer bars, word-highlight captions, colour grade, music bed.

Everything here was derived by measurement on real recordings, not by taste. Where a
number is stated, the measurement that produced it is stated too.

---

## The audio problem this solves

A conference recording made on a camera or room mic usually has three faults at once:

| Symptom | What it measures as |
|---|---|
| "Voice sounds far away / muffled" | spectral rolloff under ~1.5 kHz, tilt steeper than −8 dB/oct |
| "Too quiet next to other videos" | integrated loudness below −20 LUFS (social target is −14) |
| "Hiss / air-con behind the voice" | SNR under ~20 dB measured in a speech pause |

A video editor can't fix these — most have no EQ or compressor. This does.

```bash
brew install ffmpeg

scripts/audio-report.sh talk.mp4                 # diagnose
scripts/enhance-voice.sh talk.mp4                # fix -> talk-enhanced.mp4
scripts/audio-report.sh talk-enhanced.mp4        # verify
```

Measured on a 33-minute conference talk:

| | before | after |
|---|---|---|
| Integrated loudness | −23.3 LUFS | **−13.7 LUFS** |
| True peak | −6.0 dBTP | −1.4 dBTP |
| Spectral rolloff | 879 Hz | **3387 Hz** |
| SNR (speech vs pause) | 14.9 dB | **36.1 dB** |
| Pumping artifacts | — | 0.06 (clean) |

The video stream is copied bit-for-bit; only audio changes. Your original is never
modified — output goes to a new file.

---

## Scripts

### `enhance-voice.sh` — the rescue chain

```
high-pass → spectral denoise → presence EQ
          → voice-band-keyed expander → compressor → two-pass loudnorm
```

It **auto-calibrates**: before processing it locates the longest speech pause, measures
the actual noise floor there, and sets the denoiser floor and expander threshold from
that number. A guessed threshold below the real floor means the expander never closes;
above the speech level it chews up words. Both failure modes are silent, which is why
this is measured rather than assumed.

```bash
scripts/enhance-voice.sh in.mp4 [out.mp4]
TARGET_LUFS=-16 scripts/enhance-voice.sh in.mp4   # podcast target
AIR_G=0         scripts/enhance-voice.sh in.mp4   # mic has no real HF; don't boost hiss
NOCAL=1         scripts/enhance-voice.sh in.mp4   # skip auto-calibration
VOICE_GATE=0    scripts/enhance-voice.sh in.mp4   # old full-band gate
```
Works on video (`.mp4`, `.mov` → mp4 out) and audio (`.wav`, `.m4a`, `.mp3` → wav out).

### `audio-report.sh` — measure instead of guess

```bash
scripts/audio-report.sh file.mp4
scripts/audio-report.sh file.mp4 --find-pauses        # locate room tone
scripts/audio-report.sh file.mp4 --pause 9.6 0.7      # SNR from that pause
```

### `music-bed-gain.sh` — how loud should the bed be

Arithmetic, not taste: `volumeDb = (voice_LUFS − duck_LU) − music_native_LUFS`.
19 LU under the voice is a good default for spoken word.

```bash
scripts/music-bed-gain.sh bed.m4a          # -> "set clip volume -22.0 dB"
```

---

## What the benchmark showed

Full method and numbers in [BENCHMARK.md](BENCHMARK.md). The short version:

The expander is where nearly all the noise reduction comes from — **+21 dB SNR** on the
real talk — because it acts only in pauses and so costs no brightness. Spectral denoise
alone barely moved the number.

Consumer "AI noise cancelling" mics ([DJI](https://www.dji.com/mic-2),
[Hollyland](https://www.hollyland.com/faq/what-is-the-noise-cancellation-function)) and
[Apple's Voice Isolation](https://machinelearning.apple.com/research/coarse-to-fine-optimization-for-speech-enhancement)
all describe the same core idea: identify the voice by its **speech-band signature**
rather than suppressing everything under a threshold. Apple's patent language groups
psychoacoustic bands relative to the speech formants — Low / Middle / High range.

That idea is implementable in plain DSP: key the expander on a band-passed (300–3400 Hz)
copy of the signal instead of the full band. Measured against a clean reference:

| Noise type | full-band gate | voice-band-keyed | gain |
|---|---|---|---|
| Broadband (fills the speech band) | 45.4 dB | 47.3 dB | +1.9 dB |
| **Outside the speech band** (rumble + hiss) | 26.7 dB | **42.6 dB** | **+15.9 dB** |

with no measurable difference in voice-shape damage (0.30 vs 0.32 dB). Room tone and
air-conditioning are the second case, which is why this is the default.

**These are DSP approximations of the published principle, not implementations of any
vendor's algorithm.** Those are neural, real-time and proprietary. Note also that ANC in
headphones is a different thing entirely — physical anti-phase cancellation, not
post-production noise suppression.

---

## Tuning rules worth knowing

Each of these cost a measurement to learn:

- **Aggressive spectral denoise destroys the voice.** `afftdn nf=-35` is the useful limit.
  `nf=-40` with `nr=28` scored well on SNR but stripped **27 dB** of high frequencies —
  the file gets quieter *and* duller. Always check brightness after denoising, not just SNR.
- **Decide EQ from per-band SNR.** A typical room mic has ~27 dB SNR at 2–6 kHz (safe to
  boost) but ~10 dB above 10 kHz. Boosting "air" there amplifies hiss, not voice.
- **Measure SNR as speech-window RMS minus a known-pause RMS.** A whole-file
  `astats Noise_floor` reading is misleading and can reverse the verdict.
- **`loudnorm` needs `linear=true`** (two-pass). Single-pass runs dynamically and pumps.
- A file's lead-in is often digital silence (all zeros, reads `-inf`) and is useless as a
  noise profile. Real room tone lives between sentences.
- `agate`'s `knee` maxes at 8.

---

## The Claude Code skill

`skills/yt-short-flow/SKILL.md` drives Palmier Pro over MCP to assemble the Short.
Copy it into your skills directory:

```bash
mkdir -p ~/.claude/skills
cp -r skills/yt-short-flow ~/.claude/skills/
```

Then ask Claude Code to "make a YouTube Short from this recording". It covers the
layout maths for faking a two-camera split from one wide shot, the caption style,
and the ordering constraint that matters most: **trim dead air before adding any
overlay**, because silence removal ripple-splits every clip it touches.

Search the file for `YOUR_NAME` to set your own footer credit.

---

## Requirements

- `ffmpeg` (`brew install ffmpeg`) — that's it for the scripts
- The skill additionally needs Claude Code + the Palmier Pro MCP server

## Licence

MIT — see [LICENSE](LICENSE).
