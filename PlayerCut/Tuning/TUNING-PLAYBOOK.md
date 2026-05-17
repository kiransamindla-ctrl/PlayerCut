# Tuning Playbook

How to use the evaluation harness to go from "guessed thresholds" to "thresholds defended by data."

## Step 1: Build the corpus (one weekend)

You need 5 games minimum, 10 is better. Each game requires:

- The raw recording from the capture pipeline (`raw.mov`)
- The audio loudness sidecar from the same recording (`audio_loudness.json`)
- A human label file (`labels.json`)

For real ground truth, label your own kid's games over a season. For a faster bootstrap, use any youth-game footage you have rights to and label "moments a parent of any kid on the field would care about."

Aim for 15–25 labels per game. Importance distribution should look like:

- **Importance 5** (must-include): goals, dunks, baskets, touchdowns. 1–3 per game.
- **Importance 4** (highly desired): assists, steals, blocks, key saves. 3–6 per game.
- **Importance 3** (nice to have): skill moves, fast breaks, near misses. 5–10 per game.
- **Importance 2** (filler): sideline moments, celebrations. 2–4 per game.
- **Importance 1** (optional): general play involving the kid. Whatever's left.

## Step 2: Establish baseline

Run the harness with the default config:

```swift
let corpus = try LabeledGame.loadCorpus(at: corpusURL)
let harness = EvaluationHarness()
let baseline = await harness.evaluate(corpus: corpus, config: EvalConfig())
print(baseline.report())
```

Record these numbers — they're your "what we shipped to the first beta with" baseline. Acceptable starting point:

- Stage 1 recall: ≥ 80% (cheap detector should miss at most 20% of labeled moments)
- Stage 2 recall: ≥ 70% (after identification — losing some to "kid wasn't visible" is fine)
- **Importance-weighted reel recall: ≥ 75%** ← this is the metric that matters
- Parent satisfaction: ≥ 70%

If Stage 1 recall is already above 90%, you can probably tighten thresholds for less noise downstream. If Stage 1 recall is below 70%, no amount of Stage 2 tuning will save you — fix Stage 1 first.

## Step 3: Sweep the σ thresholds

Stage 1 has two knobs that move together. Sweep:

```swift
let results = await harness.sweep(
    corpus: corpus,
    sigmas: [1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0],
    idThresholds: [0.55]   // hold ID constant for now
)
for r in results.prefix(5) {
    print(r.report())
}
```

Look at the trade-off:

- **Lower σ** = more candidate windows = higher recall but Stage 2 takes longer
- **Higher σ** = fewer windows = faster but you miss subtle moments (a quiet defensive play with no crowd noise)

The right answer depends on your importance distribution. If your beta users care most about goals (high audio + motion), σ=2.5 is fine. If they want subtle skill moments, σ=1.75 is required.

**Decision rule:** pick the σ where **importance-weighted recall is within 2 points of its peak** AND Stage 2 duration stays under 12 minutes per game. Don't pick the absolute peak — it overfits to the corpus.

## Step 4: Sweep identification threshold

```swift
let results = await harness.sweep(
    corpus: corpus,
    sigmas: [bestSigmaFromStep3],
    idThresholds: [0.40, 0.45, 0.50, 0.55, 0.60, 0.65]
)
```

The trade-off here:

- **Lower threshold** = more "your kid" detections = higher recall, but you'll start picking up other-team kids who happen to wear similar colors. Reel quality drops.
- **Higher threshold** = stricter matching = lower recall, but every clip is unambiguously your kid.

In our experience the sweet spot is **0.50–0.55 for soccer/lacrosse** (kids spread out, easier to ID) and **0.55–0.65 for basketball** (lots of bodies in close proximity, more confusion possible).

## Step 5: Validate on a held-out game

Take one game out of the corpus before tuning, then run your final config on it. Importance-weighted recall on the held-out game should be within 5 points of corpus average. If it's much worse, you've overfit. Add more games to the corpus and re-tune.

## Step 6: Add new metrics as you learn what users care about

The current `parentSatisfactionScore` is a starting heuristic. Real signals to add over time:

- **Goal coverage rate**: % of labeled importance-5 moments included. Failing here is unforgivable.
- **Reel diversity**: did clips come from at least 4 different times in the game?
- **Boring-clip rate**: % of selected clips with no labeled moment within tolerance. Real users care about this — a reel of mediocre moments is worse than a short reel of great moments.
- **Wrong-kid rate**: % of selected clips where Stage 2 picked someone else. Catch via spot-check on labeled "playerVisible: false" moments — if your reel includes one of those, the ID failed.

Once you have these, weight them per user feedback. Goal coverage is a hard constraint; the rest are continuous.

## When to stop tuning

You're done when:

1. Importance-weighted recall ≥ 85% on a held-out game
2. Wrong-kid rate < 5%
3. Stage 1 + Stage 2 wall time ≤ 15 min on iPhone 13
4. Configuration is stable across 3 different sports (soccer, basketball, pickleball)

If you can't hit all four, ship what you have and tune in production. The eval harness is your safety net for any future change — every PR that touches the pipeline runs the corpus before merging.

## A note on negative space

The harness measures what you DID detect. It does not measure how often you'd have detected things if your model were better. The ceiling on Stage 1 recall is determined by how often interesting moments produce a measurable audio or motion signature — some quietly-played defensive moments will never be caught by σ thresholds alone.

When importance-weighted recall plateaus around 85%, the next 5 points come from adding a third Stage 1 signal (sport-specific event detection, probably ball trajectory) — not from further σ tuning. That's a months-long ML project, not a weekend's tweaking.
