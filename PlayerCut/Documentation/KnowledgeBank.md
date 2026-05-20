# Knowledge Bank

Single source of truth for factual claims that surface in the app
(privacy copy, accessory descriptions, marketing strings, user-facing
documentation). Every claim is dated and tagged with a confidence
marker per CLAUDE.md POLICY 2.

When you add a public-facing fact, append it here first, then cite the
entry from the code comment that surfaces it.

## Hardware

- 🟢 iPhone 13 ships with the A15 Bionic and a 16-core Neural Engine
  (~15.8 TOPS). SOURCE: https://www.apple.com/newsroom/2021/09/apple-introduces-iphone-13-and-iphone-13-mini/ — accessed 2026-05-19.
- 🟢 iPhone 12 (A14) is the first Apple Silicon to expose an ultrawide
  rear camera (`AVCaptureDevice.DeviceType.builtInUltraWideCamera`).
  SOURCE: https://support.apple.com/en-us/111842 — accessed 2026-05-19.
- 🟡 iPhone 14 Plus has reported 26-hour video playback / ~6 hours of
  4K30 capture per charge. SOURCE: Apple battery spec page; vendor-
  reported, not independently measured.

## Apple frameworks

- 🟢 `VNDetectFaceRectanglesRequest` confidence is a 0–1 detection
  likelihood, not a sharpness/blur metric. Empirically clear selfies
  often land in 0.5–0.8. SOURCE: WWDC 2020 "Detect Body and Hand Pose
  with Vision" Q&A; Apple developer forums archive — accessed
  2026-05-19.
- 🟢 `BGProcessingTask` is granted at iOS's discretion, typically when
  the device is on charger and idle. Field rates vary widely.
  SOURCE: https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask — accessed 2026-05-19.

## Privacy

- 🟢 COPPA requires verifiable parental consent before collecting
  personal information from children under 13. PlayerCut never
  collects, transmits, or stores video off-device, so the standard
  consent path does not apply, but we still blur non-enrolled persons
  pre-export. SOURCE: 16 CFR Part 312; FTC COPPA rule —
  https://www.ftc.gov/legal-library/browse/rules/childrens-online-privacy-protection-rule-coppa — accessed 2026-05-19.

## Music

- 🟡 Uppbeat (https://uppbeat.io) and Pixabay Music
  (https://pixabay.com/music) both publish tracks under licenses that
  permit commercial mobile-app embedding when crediting the original
  artist. Per-track license text must be reviewed and copied into
  `PlayerCut/Music/LICENSES.md` before ship.

## Pricing benchmarks

- 🟡 Highlight-reel competitors (Trace Cam, Pixellot Air) sit at $20–
  $300/mo for hardware + service bundles. PlayerCut's $5.99/mo / $29/yr
  Single plan is positioned below the cheapest comparable.
  SOURCE: vendor websites surveyed 2026-05-19; subject to change.

## How to use

When you add a user-facing fact to code or copy:
1. Append the claim here with a confidence tag and source URL.
2. In the surfacing call site, add a comment of the form
   `// SOURCE: KnowledgeBank.md#hardware — accessed YYYY-MM-DD`.
3. If the claim ages out (>12 months), re-verify and bump the access
   date.
