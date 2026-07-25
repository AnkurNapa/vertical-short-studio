# Benchmark method and results

Every number in this repo came from one of two sources: a real 33-minute conference
recording, or a controlled synthetic test with a clean reference. Both are described
here so you can disagree with the method rather than take the numbers on faith.

## Metrics

**SNR** — speech-window RMS minus the RMS of a *known speech pause*.

This is the metric that matters and the easy one to get wrong. A whole-file
`astats Noise_floor` reading conflates speech and silence; using it initially told me
an enhancement had *worsened* SNR when the pause-based measurement showed a 3.8 dB
improvement. Locate pauses with `silencedetect`, then measure inside one.

**Brightness** — RMS of the signal above 3 kHz minus full-band RMS.

A proxy for "muffled". A dull room mic sits near −19 dB or below. It exists to catch
the failure mode where a denoiser improves SNR by deleting the voice's high
frequencies — SNR goes up, the recording gets worse.

**Voice-shape damage** — mean absolute difference, across six bands
(100–300, 300–800, 800–2k, 2k–4k, 4k–8k, 8k–16k Hz), between a chain's output on
*noisy* input and the *same chain's* output on *clean* input, both loudness-matched.

Comparing against the raw clean file instead would penalise the deliberate presence
EQ as if it were damage — an error in my first attempt. Comparing chain-on-noisy to
chain-on-clean isolates what the noise handling did. Band envelopes are used rather
than sample-wise difference because some filters introduce latency.

## Test 1 — real conference talk

33 min, 1920×1080 h264, camera/room mic, single speaker with a projector screen.

| | before | after |
|---|---|---|
| Integrated | −23.3 LUFS | −13.7 LUFS |
| True peak | −6.0 dBTP | −1.4 dBTP |
| Rolloff | 879 Hz | 3387 Hz |
| Brilliance band | −20.8 dB | −11.8 dB |
| SNR | 14.9 dB | 36.1 dB |
| Pumping | — | 0.058 |

Per-band SNR of the source, which is what the EQ decisions were based on:

| band | speech | noise | SNR |
|---|---|---|---|
| mid | −25.4 | −58.1 | 32.7 dB |
| upper-mid | −26.7 | −54.7 | 28.0 dB |
| presence | −31.7 | −58.8 | 27.1 dB |
| high-mid | −33.2 | −60.1 | 26.9 dB |
| brilliance | −40.6 | −60.6 | 20.0 dB |
| **air** | −48.8 | −59.5 | **10.7 dB** |

The air band is where a naive "add sparkle" shelf does damage: at ~10 dB SNR it lifts
roughly as much hiss as voice. Hence `AIR_G=0` for mics with no real HF content.

Intermediate result worth recording — the effect of the expander alone, everything
else held constant:

| chain | SNR | brightness |
|---|---|---|
| raw | 14.91 dB | −19.00 dB |
| denoise + EQ + compressor, no expander | 18.71 dB | −22.05 dB |
| + expander @ −50 dB, ratio 2 | 30.28 dB | −22.30 dB |
| + expander @ −46 dB, ratio 3 | 42.63 dB | −22.21 dB |

The expander buys 12–24 dB at a brightness cost of ~0.25 dB, because it only acts in
pauses. Nothing else in the chain comes close to that ratio.

And the counter-example — aggressive spectral denoise, which looks fine on SNR alone:

| afftdn setting | SNR | brightness |
|---|---|---|
| `nr=28 nf=-35` | 23.11 dB | −46.76 dB |
| `nr=28 nf=-40` | 24.68 dB | −43.41 dB |
| `nr=28 nf=-45` | 21.04 dB | −38.07 dB |

Brightness collapses from −19 dB to −47 dB. SNR improved; the recording was ruined.

## Test 2 — controlled, with a clean reference

Real speech (a screen recording, 34 dB SNR raw) loudness-normalised to −20 LUFS, plus
synthetic noise at a known level. Having a clean reference is what makes the
voice-damage metric possible.

Two noise conditions, because they behave completely differently:

**(a) Pink noise across the whole spectrum** — fills the speech band too.

| chain | pause SNR | voice damage |
|---|---|---|
| no expander | 23.26 dB | 0.04 dB |
| full-band gate | 45.42 dB | 0.04 dB |
| voice-band-keyed | 47.34 dB | 0.05 dB |

**(b) Noise with a hole in the speech band** — rumble + hiss, i.e. air-conditioning and
room tone, the usual real-world case.

| chain | pause SNR | voice damage |
|---|---|---|
| no expander | 18.62 dB | 0.36 dB |
| full-band gate | 26.69 dB | 0.30 dB |
| **voice-band-keyed** | **42.60 dB** | 0.32 dB |

**+15.9 dB** for keying the expander on 300–3400 Hz instead of the full band, at no
measurable cost in voice damage. When the noise sits mostly outside the speech band, a
full-band detector sees that noise and holds the gate open; a speech-band detector
does not.

This is the one place where the vendor research translated into a concrete,
reproducible gain.

## Test 3 — ceiling fan, and multiband vs single-band

Synthetic fan noise (50 Hz hum + 100/150 Hz harmonics + low-passed turbulence) mixed
with the same clean speech. Raw SNR 13.9 dB — a realistic fan recording.

What the `fan` preset buys, measured in the band it targets:

| | hum <200 Hz | rumble <400 Hz | full band |
|---|---|---|---|
| raw | −28.6 dB | −28.4 dB | −28.1 dB |
| `room` preset | −52.0 dB | −49.1 dB | −47.5 dB |
| `fan` preset | **−55.8 dB** | **−50.0 dB** | −46.8 dB |

3.8 dB more hum removal, costing 0.7 dB more broadband residual. Note the `fan` preset
scores *slightly worse* on overall pause SNR (33.6 vs 35.0) — removing low-frequency
energy lowers the total level, so loudnorm applies more gain and lifts what remains.
Judging it on full-band SNR alone would have hidden what it actually does.

Then single-band vs multiband expansion, same input, both with the `fan` preset:

| | pause SNR | hum <200 Hz | voice damage |
|---|---|---|---|
| `gate` (single band) | 33.59 dB | −55.83 dB | 0.49 dB |
| **`multiband`** | **35.35 dB** | **−58.37 dB** | **0.47 dB** |

Better on all three, so multiband is the default. The per-band profile it measured shows
why — the fan is 29 dB louder in the bottom band than the top:

```
band 0 (0-200 Hz)      noise -32.3 dB
band 1 (200-500 Hz)    noise -39.3 dB
band 2 (500-1200 Hz)   noise -42.7 dB
band 3 (1200-3000 Hz)  noise -49.2 dB
band 4 (3000-6000 Hz)  noise -59.0 dB
band 5 (6000+ Hz)      noise -61.4 dB
```

A single threshold cannot serve both ends of that range; six can.

### A second failed measurement

The pause detector was fixed at −38 dB. A running fan sits at about −28 dB, so *no*
pause was ever detected and the tool silently fell back to default thresholds — on
exactly the recordings that most need calibrating. The detector now sweeps
−45/−38/−32/−27/−22 dB until it finds one, and reports which threshold worked.

### A failed measurement, kept deliberately

The first version of test 2 used a single noise condition and set the expander
threshold to the default −50 dB. The measured noise floor was −38.6 dB — so the
threshold sat *below* the noise and the gate never closed. Every variant scored
identically (~23 dB) and the test appeared to show the approach did nothing.

The threshold has to be calibrated to the measured floor, which is why
`enhance-voice.sh` now does that automatically rather than trusting a default.

## Reproducing

```bash
scripts/audio-report.sh yourfile.mp4 --find-pauses
scripts/audio-report.sh yourfile.mp4 --pause <start> <dur>
scripts/enhance-voice.sh yourfile.mp4
scripts/audio-report.sh yourfile-enhanced.mp4 --pause <start> <dur>
```

Pause timestamps shift after processing if the file was trimmed; re-run
`--find-pauses` on the output rather than reusing the input's numbers.

## Limitations

- Single-channel post-production only. No beamforming, no multi-mic, no dereverberation.
  Vendor systems are neural, real-time and multi-microphone; this is classical DSP
  informed by the same published principle.
- The expander cannot reduce noise *during* speech — only spectral subtraction does
  that, and only gently before it starts audibly damaging the voice.
- Numbers in test 1 come from one recording. The direction of each effect has held on
  other material; the exact magnitudes will not transfer.
- Reverb is untouched. A boomy room stays boomy.
