---
name: as-tech-story
description: >
  Retell the LAST assistant response as a high-level technical story: what happens, then what, and why, pitched at a
  competent engineer who does not need the flags. Glosses the pedantic layer (exact flags, file:line, error-string
  minutiae, edge-case caveats) while keeping every load-bearing claim and the correct cause-and-effect. Invoke with
  /as-tech-story, or when the user says "tech story this", "gloss over the details", "give me the technical story",
  "retell that simply". It reshapes the prior answer. It does no new research and invents nothing.
---

# as-tech-story

Reshape the previous answer into a technical story. This is a **simplify-and-narrate pass, not a research pass**.

## Input

- Default target: the immediately preceding assistant response in this conversation.
- If the user pasted a block or points at a different answer, use that instead.
- Do NOT investigate, read files, or run tools to enrich the story. Work only from what the target already says.

## Hard rules

1. **Never invent.** Only simplify what the source stated. If it did not give a reason or mechanism, do not
   manufacture one. Do not resolve a gap with a plausible-sounding "why". Keep the source's hedges as hedges.
2. **Keep the spine.** Every load-bearing claim survives, and the cause-and-effect order stays correct. The story
   must remain technically true, just higher-altitude.
3. **Drop the pedantic layer.** Cut exact flags, `file:line` references, error-string minutiae, config keys, version
   numbers (unless the number IS the point), and edge-case caveats that do not change the outcome.
4. **No new work.** This transforms an existing answer. It never adds findings the original did not contain.

## Shape

- A causal narrative: what happens, then what, and why, in order. Prose, not a bullet dump.
- Altitude: explain it to a competent engineer who trusts you on the details and wants the mechanism, not the manual.
- Active voice, present tense, one narrator.

## Length

Match the source's weight. Default ceiling is one short paragraph. A large or multi-part answer may run a little
longer; a small one is two or three sentences. Never pad to fill space, and never expand a one-idea answer into a
saga.

## Delivery

Hand over just the story. No preamble ("here is the simplified version"), no closing note, and no meta-commentary
about what was cut.
