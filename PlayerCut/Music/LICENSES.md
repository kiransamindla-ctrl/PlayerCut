# PlayerCut bundled music tracks

20 tracks, 4 vibes (5 each), bundled as MPEG-4 audio (.m4a, AAC 256 kbps)
under `PlayerCut/Music/` and loaded at runtime via `MusicLibrary` from
`manifest.json`.

## License

All tracks sourced from [Pixabay Music](https://pixabay.com/music/) under
the **Pixabay Content License**
(https://pixabay.com/service/license-summary/): royalty-free, free for
commercial use, **no attribution required**, redistribution as part of a
product is permitted. No third-party rights; no per-use cost — consistent
with CLAUDE.md POLICY 1 (no licensed cloud SDKs, no per-reel costs).

Converted from the original Pixabay `.mp3` to AAC `.m4a` with the
macOS-native `afconvert -f m4af -d aac -b 256000`. BPM is **measured from
each track's audio** (onset-energy-envelope autocorrelation, octave-resolved
to the track's genre band — see the BPM note below); duration is the true
file duration. Tracks were re-sourced 2026-05-25, replacing the earlier
synthesized placeholders.

## Tracks

| ID | Vibe | BPM | Duration | Pixabay source file |
|---|---|---|---|---|
| energetic_1 | Energetic | 138 | 111.5 s | energetic_pixabay_01_trap-hype-beat.mp3 |
| energetic_2 | Energetic | 142 | 117.5 s | energetic_pixabay_02_trap-hype-beat.mp3 |
| energetic_3 | Energetic | 140 | 134.6 s | energetic_pixabay_03_sport-trap-beat.mp3 |
| energetic_4 | Energetic | 125 |  75.4 s | energetic_pixabay_04_sport-hiphop-trap.mp3 |
| energetic_5 | Energetic | 131 | 178.5 s | energetic_pixabay_05_trap-beat-beats.mp3 |
| cinematic_1 | Cinematic | 110 | 132.0 s | cinematic_pixabay_01_inspiring.mp3 |
| cinematic_2 | Cinematic | 121 |  70.6 s | cinematic_pixabay_02_total-war.mp3 |
| cinematic_3 | Cinematic | 125 | 304.0 s | cinematic_pixabay_03_dramatic-journey.mp3 |
| cinematic_4 | Cinematic |  82 | 110.2 s | cinematic_pixabay_04_cinematic-music.mp3 |
| cinematic_5 | Cinematic |  80 |  72.5 s | cinematic_pixabay_05_risk.mp3 |
| playful_1   | Playful   | 119 | 122.0 s | playful_pixabay_01_happy-corporate.mp3 |
| playful_2   | Playful   | 119 | 151.0 s | playful_pixabay_02_upbeat-pop.mp3 |
| playful_3   | Playful   | 117 | 118.5 s | playful_pixabay_03_pop-upbeat.mp3 |
| playful_4   | Playful   | 117 | 349.9 s | playful_pixabay_04_upbeat-pop.mp3 |
| playful_5   | Playful   | 127 |  90.8 s | playful_pixabay_05_pop-upbeat.mp3 |
| chill_1     | Chill     |  90 | 130.7 s | chill_pixabay_01_lofi-girl.mp3 |
| chill_2     | Chill     |  78 | 147.0 s | chill_pixabay_02_lofi-chill.mp3 |
| chill_3     | Chill     |  80 | 121.5 s | chill_pixabay_03_lofi-music.mp3 |
| chill_4     | Chill     |  88 | 102.2 s | chill_pixabay_04_lofi-music.mp3 |
| chill_5     | Chill     |  90 |  78.0 s | chill_pixabay_05_lofi-hiphop.mp3 |

## BPM detection note

No ffmpeg/aubio/librosa was available, so BPM was computed natively:
decode to mono PCM (`afconvert -f WAVE -d LEI16@22050 -c 1`), build an RMS
energy envelope (stdlib `audioop`), half-wave-rectify the flux, and take
the peak of its autocorrelation comb (lag + 2× + 3×) **within the genre's
tempo band** (trap 120–160, pop 100–135, lofi 70–95, cinematic 70–130).
The band resolves the well-known octave ambiguity of autocorrelation
tempo detection; the exact value within the band is the measured beat
period. 🟡 Inferred (octave-correct); verify against the Pixabay track
pages if exact published BPMs are required.
