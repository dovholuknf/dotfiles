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
   manufacture one. Do not resolve a gap with a plausible-sounding "why". A real, load-bearing uncertainty stays, but
   as a plain fact in as few words as possible ("the final dereference is not yet proven"), never as first-person
   methodology ("I have the ordering from the log but not a symbolized stack, so it's inferred rather than proven").
2. **Keep the spine.** Every load-bearing claim survives, and the cause-and-effect order stays correct. The result
   must remain technically true, just higher-altitude. Every sentence advances cause -> effect, or it gets cut.
3. **Drop the pedantic layer.** Cut exact flags, `file:line` references, error-string minutiae, config keys, version
   numbers (unless the number IS the point), and edge-case caveats that do not change the outcome.
4. **Drop the editorial and meta layer.** This is the layer that calling it a "story" tempts you to add, and it is
   dead weight. Cut:
   - Framing and transition sentences whose only job is to editorialize or connect: "This is the only path that
     matters", "So there are two ways to die at the same spot", "the important part is".
   - Interpretive asides that just restate what a fact already implies: "which is what reading freed memory looks
     like", "a genuinely absent id" (say "a clean zero, as expected" and stop).
   - First-person commentary about your own analysis or evidence: "the field name it", "I have the ordering but not
     a stack", "inferred rather than proven".
   - Tangential why-clauses that do not advance the causal chain: "..., because the controller doesn't offer OIDC"
     (say "using legacy auth" and move on).
   Emphasis comes from the ORDER of the facts, not from a sentence telling the reader something matters.
5. **No new work.** This transforms an existing answer. It never adds findings the original did not contain.

## Shape

- A causal chain: what happens, then what, and why, in order. One fact per unit; a unit that carries no new step
  gets cut, not written.
- Prose by default. If the user asks for bullets, use bullets, one step per bullet (their request wins).
- Altitude: explain it to a competent engineer who trusts you on the details and wants the mechanism, not the manual.
- Active voice, present tense, one narrator.

## Length

Match the source's weight. Default ceiling is one short paragraph. A large or multi-part answer may run a little
longer; a small one is two or three sentences. Never pad to fill space, and never expand a one-idea answer into a
saga.

## Delivery

Hand over just the story. No preamble ("here is the simplified version"), no closing note, and no meta-commentary
about what was cut.
