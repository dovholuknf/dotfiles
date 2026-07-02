---
name: tabular
description: >
  Render the relevant data as an ASCII box-drawing table, sorted by priority, with the WHOLE table
  capped at 140 characters wide by default. Invoke when the user says "tabular", "tabular view", "render that in
  tabular", "as a table", or wants the last answer/findings reformatted into a table. Reshapes output
  format; it does not gather new data.
---

# tabular

Write the table directly as text in your reply. Do NOT write or run a script (node, python, awk, a
generator, anything) to produce it, and do NOT make any tool call. This is a formatting task you do
yourself in the message. Reaching for a tool here is always wrong and wastes the user's time.

Render the data as a single ASCII box-drawing table. Output the table and nothing else (no preamble, no
trailing prose). A one-line title above the table is allowed only if the table needs a label.

## The table

- Wrap the ENTIRE table in a fenced code block (```), so it renders monospace and the columns line up.
  A box table outside a code fence reflows in the chat renderer and the alignment breaks.
- Use box-drawing characters: `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ │ ─`. Header row, separator, then data rows.
- Pick columns that fit the data. For review findings the columns are `Sev │ Location │ Issue │ Fix`.
- Sort rows by priority, highest first. Severity order: `HIGH > MEDIUM > LOW > NIT`. If the data has a
  numeric or named priority instead, sort by that. If there is no priority, keep the given order.

## Width is fixed and exact: 140 characters total by default

The rendered width of EVERY line, borders included, is EXACTLY the width, not "at most". The table
always spans the full width, no narrower and no wider. Default width is 140. This is absolute.

- The user can set the width in the request: "use 140 chars", "200 wide", "make it 100", etc. If they
  name a number, the table is exactly that many characters wide. Otherwise it is exactly 140.
- Size the columns so their segments plus borders sum to EXACTLY the target. The content budget is
  `width - (3 * columns + 1)` characters split across the columns (borders and padding take the rest).
  Widen a column (usually Issue) to absorb any slack so the total lands on the target exactly.
- When a cell is too long for its column, WRAP it onto multiple lines inside the same cell (continuation
  lines sit in the same column, other columns blank on those lines). Do NOT widen the table past the cap.
- Give the most information-dense column (usually Issue) the widest share, and keep short columns (Sev,
  Location) narrow.
- Never let a single unbroken token blow the cap. Break a long path or identifier across lines if needed.
- Never truncate a cell with `...`. Wrap it onto the next line instead. Losing content defeats the table.

### Alignment discipline (this is where box tables usually break)

Every column has ONE fixed width, chosen up front. The rule that keeps borders straight: EVERY rendered
line in a column must be exactly that width, no exceptions.

- Before drawing, pick each column's inner width. The separator/border segment for that column is
  `width + 2` (one pad space each side).
- Wrap each cell's text to at most the column width. If a single token (e.g.
  `startExtraWorkerIfQueueBusy`) is longer than the column width, BREAK it across lines. A token wider
  than its column is what shoves the `│` out of line.
- Pad every wrapped line with trailing spaces to exactly the column width, including blank continuation
  lines. A line that is even one character short or long misaligns every row below it.
- Sanity check before sending: the top border, every row line, and the bottom border must all be the
  same character count AND equal the target width exactly (140 or the number the user gave). If any line
  differs, a column is mis-sized, fix it.

## Markdown mode

If the user asks for markdown (says "render with markdown", "as markdown", "markdown table", or similar),
skip the box-drawing entirely and emit a GitHub-flavored pipe table instead:

- `| Sev | Location | Issue | Fix |` with a `| --- | --- | --- |` separator row, then the data rows.
- The renderer handles column widths and wrapping, so do NOT hand-pad, do NOT chase the width cap,
  and do NOT wrap it in a code fence (a fence would show the raw pipes instead of a rendered table).
- Same content rules: sorted by priority, terse cells, file:line intact, no invented filler.

Default (no markdown request) is the box-drawing table above.

## Content

- Terse cells: as detailed as correctness needs, no more. Fragments over sentences ("clamp negatives to
  0", not "You should clamp the negative values to zero").
- Keep file:line references intact and copy-pasteable.
- Do not invent columns of filler. If a fix is unknown, say `investigate` rather than padding.

## Scope

- Print the table inline in the chat. Do NOT write it to a file unless the user asks for a file.
- This skill only reformats data already in play (the last answer, a review result, a list). It does not
  go fetch or compute new data.
