---
name: yt-short-flow
description: Turn a long screen recording (or any raw talking-head / demo video) into a polished vertical YouTube Short in Palmier Pro — 9:16 1080x1920, footage fit-to-width over a blurred fill background, dark header + footer bars, viral UPPERCASE Helvetica Neue captions with an orange word-highlight block on a dark readability bar, denoised + level-boosted voice, dead-air trim, a subtle color grade, and a looped music bed sitting 19 LU under the voice. Includes a measured ffmpeg audio-rescue chain (EQ + expander + loudnorm to -14 LUFS) for dull or noisy room-mic sources, applied via media relink so every Short inherits it. Use whenever the user asks to make a YouTube Short, Reel, TikTok, or any vertical short from a recording. Drives the palmier-pro MCP tools directly.
---

# YT Short flow — long recording → polished vertical Short

Battle-tested pipeline (built iteratively against real recordings). Produces a clean, viral-style vertical Short.
The house style and the exact numbers below are the point — match them unless the user asks otherwise.

## House style (locked defaults)
- **Canvas:** 9:16, 1080x1920. (Palmier resets an EMPTY timeline to the first clip's native size on `add_clips` — re-apply `set_project_settings 9:16 1080p` AFTER placing the first clip.)
- **Font everywhere:** `fontName: "HelveticaNeue-Bold"` (the PostScript name — passing `"Helvetica Neue"` + `bold:true` silently does NOT apply the bold face), `fontCase: uppercase`.
- **SOLID TEXT, NO OUTLINE.** Deliberate style choice. Every text and caption style gets
  `outline: {enabled:false, width:0}` — solid fill + soft shadow only. Never a stroked/hollow look.
- **Accent color:** light orange `#FFB490` (title) and orange `#FF5A1F` (caption word-highlight block).
- **Header/footer bars:** solid dark `#0D0D12`, 92% opacity, ~15% frame height each.
- **Captions:** white text, soft shadow, NO outline, on a dark rounded readability bar (`#101014` @ ~0.78 opacity, cornerRadius 18) — the bar is what makes text readable over a bright blurred background. Animation `highlightBlock`, highlightColor `#FF5A1F`, `maxWords: 4`, fontSize 58–62. centerY 0.64 for a single-panel Short, 0.75–0.80 when a presenter panel sits below the main panel.
- **Footer credit (locked):** `YOUR_NAME | YOUR_TAGLINE` — fontSize 25, white, centerY 0.93.
- **Audio targets (measure, don't guess):** finished Short at **−14 LUFS integrated, ≤ −1 dBTP**. Voice denoised ~0.6–0.85 + boosted ~+4 dB is fine for a *clean* source. Music bed **19 LU under the voice** — with the sample bed (−11.0 LUFS native) that is **−22 dB**, NOT −42 dB. −42 dB was a mistake carried through several Shorts: it puts the bed 39 LU down, i.e. inaudible.
- If the source is a dull room/camera mic, the in-Palmier controls cannot fix it — see **Audio rescue** below.

## Renderer landmines (verified the hard way — these render BLACK, not "subtly wrong")
- `blur.gaussian` **radius 55 renders the clip black** on a heavily upscaled background copy. **Use radius 30.**
- `stylize.vignette` on that same upscaled bg copy **renders it black**. **Don't use it.** To darken the
  background instead, grade it: `apply_color exposure:-0.85 saturation:0.85 contrast:0.9`. Looks better anyway.
- `edgeRounding` on a cropped+transformed panel clip **stops it rendering entirely**. Leave it at 0.
- After ANY of these, `inspect_timeline` before exporting — the failure mode is a silently black region.

## The one gotcha that ruins it (READ THIS)
`remove_silence` ripple-splits **every** overlapping clip into fragments (a 3-min clip can become 30+ pieces).
If you add the title / captions / bars BEFORE trimming silence, they fragment too — and any later restyle that
targets one clip id only changes that fragment, so the style flickers mid-play.
**→ Do dead-air trim FIRST, then add all single-clip overlays (title, bars, footer, captions) on the final timeline.**

**The corollary that saves ~20 tool calls per Short:** every *footage* treatment — `apply_layout`, `crop`,
`transform`, `apply_color`, `apply_effect`, `denoise_audio`, `volumeDb` — is a static field that **propagates
to every fragment** when `remove_silence` splits the clip. So do ALL footage work on the single un-split clip
FIRST, then trim. If you trim first you have to re-read the timeline and re-apply each grade/effect across
20+ fragment ids by hand.

Correct order: place all footage copies → layout/crop/transform/grade/blur → denoise + volume →
`remove_silence` → bars → title → footer → captions → music → verify → export.

## Workflow (in this order)

### 0. Inspect
- `get_media` / `get_timeline`. `inspect_media(overview:true)` + read the transcript segments to find the strongest ~30–60s (or the span the user wants). Note: screen recordings are often ~80% silence — warn the user the trim will shorten it a lot, and confirm target length.

### 1. New vertical timeline
- `create_timeline` (name e.g. "YT Short") to keep the source timeline intact.
- `set_project_settings aspectRatio:9:16 quality:1080p`.

### 2. Place footage + blurred background (BOTH before the trim)
- `add_clips` the chosen segment (`source:[start,end]`) at frame 0. **Re-apply `set_project_settings 9:16 1080p`** (empty-timeline reset).
- `add_clips` the SAME segment again = background copy. `apply_layout full fit:fill` on it (cover-crops to fill vertical), then `apply_effect` `blur.gaussian radius:55` + `stylize.vignette amount:0.5`.
- `manage_tracks` reorder so main footage is ABOVE the blurred bg; `set` the bg's linked-audio track `muted:true` (kill the doubled audio).
- Main footage: `set_clip_properties transform:{centerY:0.33}` (sit it high, leaving room for captions).

### 3. Clean the voice, then trim dead air
- `denoise_audio` on the main voice clip (strength 0.6–0.85) and `set_clip_properties volumeDb:+4`.
- `remove_silence` (no args; amplitude/waveform-based). Re-read `get_timeline` — footage + bg are now fragmented but in sync. This is the final duration.

### 4. Header + footer bars (single clips)
- `import_media {matte:{hex:"#0D0D12", aspectRatio:"Project"}}` → one dark PNG.
- `add_clips` it twice, each on its own new track, spanning [0,end]. Header: `transform{centerX:.5,centerY:.075,width:1,height:.15}`; footer: `centerY:.925`. `opacity:0.92`.
- `manage_tracks` reorder: text tracks (captions, title) on top, then the two bars, then footage, then bg.

### 2b. Split screen from a SINGLE wide camera (speaker + slide in one shot)
Conference/talk footage is usually one wide shot containing both the speaker and the projector screen.
You can fake a two-camera split by placing the SAME source twice and cropping each copy differently.

**First check the speaker is actually on camera** for the span you picked — these recordings zoom between
"speaker + screen" and "screen only", and a fixed presenter crop over a screen-only stretch shows an empty
podium. `inspect_media` 4 frames across the window before committing.

**Crop is applied AFTER the transform** — it cuts into the already-placed rect (that's why `apply_layout full
fit:fill` pairs `width:3.16` with `crop left/right 0.342`: 3.16 × 0.316 = 1.0). So to get a panel of a given
on-canvas size you must inflate the transform to compensate:

    visibleW = 1 − left − right          visibleH = 1 − top − bottom
    transform.width  = desiredW / visibleW
    transform.height = transform.width / sourceAspect      (sourceAspect = 1.778 for 1920x1080)
    transform.centerX = desiredLeftEdge + transform.width  × (left + visibleW/2) − transform.width/2
    transform.centerY = desiredTopEdge  + transform.height × (top  + visibleH/2) − transform.height/2

Worked example (1080x1920 canvas, 1920x1080 source), screen panel full-width under the header bar:
`crop {top .04, right .01, bottom .14, left .36}` → `transform {centerX .2222, centerY .3609, width 1.587, height .502}`
Presenter panel full-width below it:
`crop {top .40, right .50, bottom .05, left 0}` → `transform {centerX 1.0, centerY .6083, width 2.0, height .6328}`

Set the crop with `set_keyframes property:"crop" [[0, top, right, bottom, left, "hold"]]` — a single row is
stored as the static `crop` field and propagates through `remove_silence` like any other static field.
Stack: presenter panel on top, screen panel, blurred bg at the bottom. Mute the extra copies' audio tracks
(`manage_tracks set muted:true`) — keep exactly one as the voice.

### 5. Title + footer text (single clips — add AFTER the trim)
- Title via `add_texts`, one clip [0,end]: content on 2 lines, `fontCase:uppercase`, bold, `#FFB490`, shadow on, NO outline (it sits on the dark bar). Lock the box `transform:{centerX:.5,centerY:.078,width:.98,height:.145}`, `fontSize` ~33 so both lines fit — uppercase is wide, so keep the font small enough not to wrap/clip.
- Footer credit via `add_texts`, one clip: **`YOUR_NAME | YOUR_TAGLINE`** (the locked default — don't substitute "Built with Claude Code + Palmier Pro", that was retired), `fontSize` ~25, white, `centerY:0.93`, locked box.
- **Whenever you change a text clip's style/content, pass the locked 4-field `transform` in the SAME call** — otherwise the box auto-refits and re-wraps.

### 6. Captions (viral style)
- `add_captions maxWords:4 animation:highlightBlock highlightColor:"#FF5A1F" transform:{centerY:0.64}` with style: `fontName:"Helvetica Neue"`, `fontSize:62`, bold, white, `fontCase:uppercase`, outline `#000000` width 2–3, shadow on, background `{enabled:true,color:"#101014",opacity:0.72,cornerRadius:18,padding:{x:26,y:16}}`.
- Read the captions (`get_timeline captionDetail:true`) and fix the recurring auto-transcription errors with `update_text` per clip (brand/tech terms especially — e.g. "Clot code"→"Claude Code", "W public"→"Tableau Public", "playwright"→"Playwright", "1st"→"first"). Corrected clips lose per-word highlight timing — acceptable.

### 7. Color grade the footage
- `apply_color` on ALL footage fragments (subtle punch, keep the screen legible): `contrast:1.12, vibrance:0.18, saturation:1.06, blacks:-0.03`.

### 8. Music bed
- `import_media` a music track (path or url). If none: reuse `~/Library/Application Support/PalmierPro/Samples/sample-palmier/Palmier Sample.palmier/media/gen-14EB3F30.m4a`. (AI `generate_audio` needs the user signed in + credits; a local file needs neither.)
- If the track is shorter than the Short, `add_clips` it back-to-back to cover the length (trim the last with `source:[0,sec]`).
- Set the bed **19 LU under the voice**, computed not guessed:
  `volumeDb = (voice_LUFS − 19) − music_native_LUFS`
  Measure the music's native loudness once: `ffmpeg -i bed.m4a -af ebur128 -f null -`.
  For the sample bed (−11.0 LUFS native) against a −14 LUFS voice → **`volumeDb: -22`**.
- `fadeInFrames: 25` on the first clip, `fadeOutFrames: 25–40` on the last. Check the last clip actually HAS a
  fade — a bed that was inaudible hid the hard cut; once it's audible the abrupt stop is obvious.

### 9. Verify + export
- `inspect_timeline` at several frames — check caption contrast over the BRIGHT parts of the blurred bg, and that the title/footer read cleanly. Fix low-contrast spots by keeping the dark caption bar.
- `export_project mode:video codec:H.264 resolution:"Match Timeline" outputPath:"~/Downloads/<name>.mp4"`. Re-export to the same path after each tweak; `manage_exports` to check progress / cancel a stale render before re-exporting.

## Audio rescue — dull / quiet / noisy source (verified 2026-07-25)

**Palmier has no EQ and no compressor** — only `denoise_audio` and `volumeDb`. A muffled room-mic talk
("voice not coming clearly") is therefore unfixable inside Palmier. Fix it on the source with ffmpeg, then
relink, so every Short inherits it without re-cutting a single clip.

**Diagnose first** (`earshot` MCP `audio_measure`, or `ffmpeg -af ebur128`). Symptoms that mean "rescue needed":
integrated below ~−20 LUFS, spectral rolloff under ~1.5 kHz, tilt steeper than −8 dB/oct.

**The chain** (two-pass loudnorm, `linear=true` so it applies constant gain and cannot pump):

```
highpass=f=85,afftdn=nr=12:nf=-35,
equalizer=f=200:t=q:w=1.0:g=-3,
equalizer=f=2800:t=q:w=1.0:g=6,
equalizer=f=5500:t=q:w=1.2:g=5,
treble=g=4:f=9000,
agate=threshold=-50dB:ratio=2.5:attack=20:release=350:knee=8,
acompressor=threshold=-20dB:ratio=3:attack=8:release=180:makeup=2,
loudnorm=I=-14:TP=-1.5:LRA=9
```
Measured on a conference talk: −23.3 → −13.7 LUFS, rolloff 879 → 3387 Hz, SNR 14.9 → 36.1 dB, pumping 0.06.

**Better: key the expander on the SPEECH BAND, not the full band.** Consumer "AI noise cancelling" mics (DJI,
Hollyland) and Apple's Voice Isolation all describe the same principle — identify the voice by its speech-band
signature instead of suppressing everything under a threshold. In plain DSP that is a `sidechaingate` whose
detector is a band-passed copy of the signal:

```
[0:a]<hpf,afftdn,EQ>[m];[m]asplit=2[main][det];
[det]highpass=f=300,lowpass=f=3400[sc];
[main][sc]sidechaingate=threshold=<T>dB:ratio=2.5:attack=20:release=350:knee=8[g];
[g]<compressor,loudnorm>[out]
```
Benchmarked against a clean reference: broadband noise 45.4 → 47.3 dB SNR (+1.9), but noise sitting OUTSIDE
the speech band (rumble + hiss — air-con, room tone, the usual case) 26.7 → **42.6 dB (+15.9)**, with no
measurable voice-shape damage (0.30 vs 0.32 dB). Use the sidechain version by default.

**Calibrate the threshold from a measured pause — always.** A threshold below the real noise floor means the
expander never closes and the whole thing does nothing; above the speech level it chews words. Both fail
silently. Find the longest pause with `silencedetect`, measure its RMS, set the denoise floor at that value
and the expander threshold ~5 dB above it.

**Tuning rules learned by measurement — don't re-derive:**
- The **expander is the noise-removal win**: +12 to +24 dB SNR at ~zero brightness cost, because it
  only acts in pauses. Place it **after the EQ, before the compressor** so the compressor can't re-lift noise.
- **Aggressive `afftdn` destroys the voice.** `nf=-35` is the useful limit; `nf=-40 nr=28` cost 27 dB of HF.
  `nf=-50` barely denoises. Set `nf` from a measured pause, then verify brightness didn't collapse.
- **Decide EQ from per-band SNR.** Typical room mic: ~27 dB SNR at 2–6 kHz (safe to boost) but ~10 dB above
  10 kHz — boosting "air" amplifies hiss, not voice.
- **Measure SNR as speech-window RMS minus a known-pause RMS.** A whole-window `astats Noise_floor` reading
  is misleading and can reverse the verdict.
- `agate` `knee` maxes at 8. Find real pauses with `silencedetect`; a file's lead-in is often digital silence
  (all zeros, `-inf`) and useless as a noise profile.

**Apply to all Shorts at once** — never re-cut the fragments. Build an enhanced source
(`-c:v copy`, audio replaced, identical duration), then:
1. `manage_project close` — Palmier rewrites the package on save and will clobber the edit
2. edit `<project>.palmier/media.json` → `entries[].source.external.absolutePath` (back it up first)
3. `manage_project open`, confirm with `get_media` that duration/`hasAudio` still resolve

Every clip's trims still line up. Then on the presenter clips: **`denoise_audio enabled:false`** (ffmpeg already
denoised; DeepFilterNet on top just re-dulls it) and **`volumeDb: 0`** — leaving the old +4 dB on a −14 LUFS
master clips at +2.5 dBTP.

Harvest the clip ids from `project.json` (`timelines[].tracks[].clips[].id`, first 8 chars) instead of five
verbose `get_timeline` reads.

## Palmier gotchas (verified)
- Switching projects can drop the MCP session's target and the app foreground — `manage_project open` by `path`, and the app's visible project must match or edits are refused.
- Empty timeline adopts the first placed clip's resolution → re-set 9:16 after the first `add_clips`.
- `add_texts.transform` needs `{centerX,centerY}` or all four; content/style edits auto-refit unless you pass the 4-field box.
- Two full-frame overlays can't share one track (same time range overwrites) — give each its own track.
- Sign-in state: generation (`generate_*`, `upscale`) needs signed-in + credits (`canGenerate:true`); captions/denoise/silence/grade/import are local and free.
