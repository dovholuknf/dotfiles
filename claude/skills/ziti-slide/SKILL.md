---
name: ziti-slide
description: >
  Generate a 1920x1080 SVG slide, YouTube thumbnail, or architecture diagram in Clint's OpenZiti
  visual style (dark navy, teal/blue accent gradient, grid, floating terminal cards). Invoke when the
  user asks for a thumbnail, title slide, architecture diagram, deck slide, or "one of those slides"
  for an OpenZiti video, talk, or doc. Produces a self-contained SVG file; it does not publish or
  upload anything.
---

# ziti-slide

Write a **self-contained 1920×1080 SVG** to a file. No external fonts, no embedded images, no scripts.
The user opens it in a browser to review and converts to PNG when needed.

Never write a generator script. Author the SVG directly.

## Non-negotiables

- Canvas exactly `width="1920" height="1080" viewBox="0 0 1920 1080"`.
- Margins: keep all content inside a 96px border. Nothing closer than 90px to any edge.
- **Never write naked "Ziti"** in visible text. Always "OpenZiti". This is a hard brand rule and the
  user has corrected it before. `ziti` lowercase is fine when it's the literal CLI binary, a config
  key, a service name, or a hostname (`ziti login`, `mgmt.ziti`, `ziti-edge-tunnel`).
- Font stack, verbatim, on the root `<svg>`:
  `font-family="Inter, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"`
- Monospace, verbatim, wherever code/config/ports appear:
  `font-family="ui-monospace, 'JetBrains Mono', Consolas, monospace"`
- Wordmark `OPENZITI` bottom-right, `text-anchor="end"`, `x="1800"`, `y≈1042`, `fill="#4E7391"`,
  `font-size="28-32"`, `font-weight="700"`, `letter-spacing="4"`.

## Palette

| role | hex |
|---|---|
| bg gradient | `#0B1B2E` → `#071322` (55%) → `#040B14` |
| accent teal | `#00E3B0` |
| accent blue | `#28C2FF` |
| card fill | `#12293F` → `#0A1A2B` at 0.97 opacity |
| shell/container fill | `#0D2135` → `#081625` at 0.7 opacity |
| card stroke (normal) | `#2C5F84` |
| container stroke | `#25506F` |
| grid line | `#1B3B5A` at 0.3–0.35 opacity |
| headline text | `#F2F8FF` |
| body text | `#9FBDD4` |
| label / eyebrow text | `#7FA6C4` |
| dim text, code punctuation | `#5E819C` |
| dimmest, footnotes | `#456C88` |
| wordmark | `#4E7391` |
| warning badge | `#FFC64D` |
| danger dot | `#FF6B6B` |
| chip fill (neutral) | `#173A57` |
| chip fill (accent) | `#0E3D33` stroke `#1C6B5A` text `#8FE8D5` |

Accent is always the teal→blue gradient left-to-right, never a flat teal, on headlines and rules.

## Boilerplate defs — copy this into every slide

```svg
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#0B1B2E"/>
    <stop offset="55%" stop-color="#071322"/>
    <stop offset="100%" stop-color="#040B14"/>
  </linearGradient>

  <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0%" stop-color="#00E3B0"/>
    <stop offset="100%" stop-color="#28C2FF"/>
  </linearGradient>

  <linearGradient id="cardFill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="#12293F" stop-opacity="0.97"/>
    <stop offset="100%" stop-color="#0A1A2B" stop-opacity="0.97"/>
  </linearGradient>

  <linearGradient id="shellFill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="#0D2135" stop-opacity="0.7"/>
    <stop offset="100%" stop-color="#081625" stop-opacity="0.7"/>
  </linearGradient>

  <radialGradient id="glow" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="#00E3B0" stop-opacity="0.28"/>
    <stop offset="100%" stop-color="#00E3B0" stop-opacity="0"/>
  </radialGradient>

  <pattern id="grid" width="60" height="60" patternUnits="userSpaceOnUse">
    <path d="M60 0H0V60" fill="none" stroke="#1B3B5A" stroke-width="1" stroke-opacity="0.32"/>
  </pattern>

  <filter id="lift" x="-30%" y="-30%" width="180%" height="180%">
    <feDropShadow dx="0" dy="24" stdDeviation="28" flood-color="#020609" flood-opacity="0.7"/>
  </filter>

  <marker id="arrowGrey" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="8" markerHeight="8"
          orient="auto-start-reverse">
    <path d="M1 1 L11 6 L1 11 z" fill="#6E93B0"/>
  </marker>
  <marker id="arrowTeal" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="8" markerHeight="8"
          orient="auto-start-reverse">
    <path d="M1 1 L11 6 L1 11 z" fill="#00E3B0"/>
  </marker>
</defs>
```

Background, always these four lines in this order:

```svg
<rect width="1920" height="1080" fill="url(#bg)"/>
<rect width="1920" height="1080" fill="url(#grid)"/>
<ellipse cx="1500" cy="300" rx="620" ry="500" fill="url(#glow)"/>
<ellipse cx="220" cy="1000" rx="520" ry="360" fill="url(#glow)" opacity="0.5"/>
```

Move the glow ellipses so they sit *behind the busiest corner* — they exist to lift the focal area off
the grid, not for symmetry.

## Components

**Eyebrow + rule** (top-left, on every slide):

```svg
<text x="120" y="150" fill="#7FA6C4" font-size="36" font-weight="600" letter-spacing="7">OPENZITI 2.0</text>
<rect x="120" y="178" width="132" height="10" rx="5" fill="url(#accent)"/>
```

On diagram slides shrink the eyebrow to `font-size="28" letter-spacing="7"` and put a real title under it.

**Two-line headline**, second line in the accent gradient. This is the signature move:

```svg
<text x="116" y="400" fill="#F2F8FF" font-size="116" font-weight="800" letter-spacing="-3">MANAGEMENT API</text>
<text x="116" y="532" font-size="116" font-weight="800" letter-spacing="-3" fill="url(#accent)">WITH NO PORT</text>
```

**Terminal card** — the recurring hero element. Title bar with three dots and a filename, then
monospace body, then one dim footnote line:

```svg
<g transform="translate(1170,214)" filter="url(#lift)">
  <rect x="0" y="0" width="640" height="400" rx="24" fill="url(#cardFill)" stroke="#2C5F84" stroke-width="2"/>
  <path d="M0 24a24 24 0 0 1 24-24h592a24 24 0 0 1 24 24v48H0z" fill="#143352"/>
  <circle cx="38" cy="48" r="9" fill="#FF6B6B"/>
  <circle cx="68" cy="48" r="9" fill="#FFC64D"/>
  <circle cx="98" cy="48" r="9" fill="#00E3B0"/>
  <text x="138" y="57" fill="#7FA6C4" font-size="23"
        font-family="ui-monospace, 'JetBrains Mono', Consolas, monospace">ctrl.yaml</text>
  <g font-family="ui-monospace, 'JetBrains Mono', Consolas, monospace" font-size="30">
    <text x="42" y="142" fill="#5E819C">bindPoints:</text>
    <text x="42" y="194" fill="#5E819C">  - <tspan fill="#28C2FF">identity</tspan>:</text>
    <text x="42" y="246" fill="#5E819C">      file: <tspan fill="#F2F8FF">ctrl.json</tspan></text>
    <text x="42" y="298" fill="#5E819C">      service: <tspan fill="#00E3B0">mgmt</tspan></text>
    <text x="42" y="360" fill="#456C88" font-size="26">no interface — no port</text>
  </g>
</g>
```

The title-bar `<path>` is `width - 48` for the horizontal segment. Recompute it when you resize the card
or the rounded corners break.

Code colouring: structure/punctuation `#5E819C`, keys being emphasised `#28C2FF`, values `#F2F8FF`, the
one value that is the point of the slide `#00E3B0`.

**Status card** (small labelled box, used in pairs to contrast):

```svg
<rect x="0" y="0" width="392" height="112" rx="18" fill="url(#cardFill)" stroke="#25506F" stroke-width="2"/>
<circle cx="46" cy="56" r="15" fill="#3E5F7A"/>
<text x="82" y="48" fill="#8FB0C8" font-size="26" font-weight="600" letter-spacing="2">PUBLIC :1280</text>
<text x="82" y="84" fill="#5E819C" font-size="24"
      font-family="ui-monospace, 'JetBrains Mono', Consolas, monospace">edge-client · oidc</text>
```

The highlighted one of a pair gets `stroke="#00E3B0"`, a `#00E3B0` dot, `#DFF9F2` label, `#00E3B0` sub.

**Chip** (API bindings, tags):

```svg
<rect x="1146" y="500" width="176" height="42" rx="21" fill="#173A57"/>
<text x="1234" y="528" fill="#A8C6DC" font-size="21" font-weight="600" text-anchor="middle">edge-client</text>
```

Width chips at roughly `12 * len(label) + 40`, and centre the text at `x + width/2`.

**Corner badge** on a card, right-aligned inside it:

```svg
<text x="1758" y="424" fill="#FFC64D" font-size="21" font-weight="700" text-anchor="end"
      letter-spacing="2">INTERNET-FACING</text>
```

Amber `#FFC64D` for exposure/warning, teal `#00E3B0` for the safe/dark state.

**Container/shell** for grouping (a controller, a host, a VPC):

```svg
<rect x="1074" y="300" width="756" height="640" rx="30" fill="url(#shellFill)" stroke="#25506F" stroke-width="2"/>
<text x="1110" y="352" fill="#7FA6C4" font-size="25" font-weight="700" letter-spacing="5">CONTROLLER</text>
```

**Flow arrows.** Dashed grey for ordinary/public traffic, solid teal for the path the slide is about:

```svg
<path d="M470 496 C700 452 880 420 1104 452" fill="none" stroke="#6E93B0" stroke-width="4"
      stroke-dasharray="12 10" marker-end="url(#arrowGrey)"/>
<path d="M928 648 C1000 664 1030 716 1104 736" fill="none" stroke="#00E3B0" stroke-width="4"
      marker-end="url(#arrowTeal)"/>
```

Label every arrow, `font-size="25" font-weight="600"`, in the arrow's own colour, placed clear of the
curve. Markers need solid stroke colours — a gradient stroke will not tint the arrowhead.

**Caption** (diagram slides), one sentence at the bottom:

```svg
<text x="96" y="1006" fill="#9FBDD4" font-size="30" font-weight="500">One sentence of payoff.</text>
```

## Type scale

| use | size | weight |
|---|---|---|
| thumbnail headline | 116–134 | 800, `letter-spacing="-3"` |
| slide title | 76 | 800, `letter-spacing="-2"` |
| kicker / subtitle | 48 | 500 |
| card headline value | 30–34 | 700 |
| eyebrow, container label | 25–36 | 600–700, `letter-spacing="5-7"` |
| code | 30–32 | normal |
| card sub-label, caption | 21–26 | 500–600 |

Thumbnails: two headline lines, ≤14 characters each. Anything longer collides with a right-hand card
and forces the size down until it stops reading at YouTube's sidebar size.

## Layout rules that stop the mistakes I actually made

- **Estimate text width before placing anything to its right.** Bold sans at `font-size` F runs about
  `0.62 * F` per character; monospace about `0.60 * F`. A 14-character headline at 128px is ~1110px
  wide — it will run under a card placed at x=1070.
- A floating card beside a headline reads best top-aligned near the eyebrow (`y≈214`), overlapping the
  headline's *vertical* band while staying clear of it horizontally. That "floating over the title"
  look is what the user asked for by name; do not solve collisions by pushing the card below the
  headline, shorten the headline instead.
- Vertical rhythm on a thumbnail: eyebrow 150 → headline 400 / 532 → kicker 630 → status cards 716.
- Always apply `filter="url(#lift)"` to cards that float over the background, and never to the
  background rects or the grid.
- Put `<g filter="url(#lift)">` around **only** the `<rect>`, then draw text as siblings after it.
  Wrapping text in the shadow filter blurs it.

## Before you hand it over

1. Re-read every `<text>` and mentally measure it against the next element's `x`. Overlap is the one
   failure the user always spots first.
2. Grep your own output for naked `Ziti` in visible text.
3. Confirm the wordmark, eyebrow, and 96px margins are all present.
4. Check no `<defs>` id is referenced but undefined, and no stray placeholder text survived.
5. Offer the PNG conversion and say the palette is swappable:
   ```bash
   magick -density 96 slide.svg slide.png
   rsvg-convert -w 1920 -h 1080 slide.svg -o slide.png
   ```

## Reference implementations

Built during the "management API with no port" video, in the `openziti/ziti` worktree
`discourse-5969`:

- `thumbnail-identity-bindpoint-v3.svg` — the approved thumbnail: two-line headline, floating terminal
  card top-right, paired status cards.
- `slide-architecture.svg` — the diagram: clients → edge router → controller shell holding two listener
  cards, dashed-grey vs solid-teal flows, bottom caption.
- `thumbnail-identity-bindpoint.svg` and `-v2.svg` — earlier passes kept for comparison. v1 had the
  headline running under the card; v2 pushed the card below the headline and lost the floating look.

If those files are reachable, read v3 and the architecture slide first — they are the style, and this
document is the summary of them.
