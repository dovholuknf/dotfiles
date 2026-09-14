---
name: review-work
description: >
  Reshape a feature or change into a manual-test card the user can run by hand: a title, a SHORT "what this is
  doing" blurb, and a precise "what to test" click-path that always starts from the app's main landing page.
  Invoke with /review-work, or when the user says "walk me through testing this", "turn this into a test",
  "review-work", "make me a test card", or hands over a feature to verify by clicking through. It reformats the
  feature under discussion into the fixed shape below; it does not run the test or change code.
---

# review-work

Turn the feature under discussion into one manual-test card the user runs by hand. Output ONLY the three parts
below, in this order, nothing before or after. If several features are in play, emit one card each, separated by a
blank line and a `---`.

## The shape (exact)

**Title** — one line. Keep the user's numbering if they gave one. Format: `<N.N> — <short lowercase name>`
(e.g. `8.2 — a blocked ask moves the card`). No number given: just the short name.

**What this is doing:** one short paragraph. HARD CAP 40 words, shorter whenever possible. Say what the feature does,
why the user asked for it, and what prompted building it. High-level, in the as-tech-story voice: no flags, no
file:line, no config keys, no edge-case caveats. Every word load-bearing. Cut it until only the point remains.

**What to test:** a numbered click-path the user can follow blind. Rules:
- ALWAYS start from the app's main landing page. Never assume the user is already on a tab, a card, or a dialog.
  Step 1 is a move from the landing page.
- One action per step, in order, each concrete and specific: which link/tab to click, which card by its title,
  which button by its label. No "navigate to" or "go find" hand-waving.
- End with the expected result(s) to observe, as a short "Expect:" list. Name what should change on screen (a card
  moves column, a chip appears, a sort order, a notification and its exact wording) so a wrong outcome is obvious.
- If a step needs a shell command (e.g. `atrium ask "..."`), give it verbatim on its own step.

## Rules

- Terse. No marketing adjectives, no preamble, no "in this test we will". The card is the whole output.
- The "what this is doing" blurb is the one place brevity matters most: 40 words is the ceiling, not the target.
- Precision in "what to test" is the point: the user is clicking exactly what you write, from a cold start, so a
  vague step is a failed test. When you are unsure of the exact label or path, say so in the step rather than
  inventing one.
- Do not invent behavior. Only describe what the feature actually does; if a detail is unknown, mark it, don't guess.

## Example (shape only)

8.2 — a blocked ask moves the card

**What this is doing:** Proves a blocked `ask` stops a card, unlike `--working` which keeps it going. A stopped card
should read as "waiting on you", not "quietly done", because a question deserves more attention.

**What to test:**
1. From the atrium landing page, click the **Stack** tab.
2. Find the row titled **main:atrium**. Note its column (it should read `running`).
3. In a shell for that session, run: `atrium ask "which branch is base"`
4. Watch the board.

Expect:
- The card moves to the **waiting on you** column.
- It shows an **asked you** chip, distinct from a card that merely ended its turn.
- It sorts ABOVE cards that just went quiet.
- If alerts are on, a desktop notification says the card asked you something, not that it is ready.
