# Clint's voice, by register

This file is the gold standard for prose written for or by Clint Dovholuk (OpenZiti / NetFoundry). It is derived from
samples he wrote, not from generic style advice. **When any rule in an agent definition disagrees with this file, this
file wins.** Say in your report which default you set aside.

Two registers. They are not interchangeable, and mixing them is the most common failure. Decide which one applies before
editing a sentence.

## Shared across both registers

- Long sentences are correct. Comma-heavy, with which/that clauses and subordinate clauses carrying real weight. Do not
  split a sentence just because it exceeds twenty words.
- Triples and anaphora are deliberate rhythm, not a tell: "the easiest, fastest, and, of course, most expensive way",
  "no need to open ports, no need to expose services, no attack surface". Leave them.
- Semicolons are allowed and appear in his published work: "one substantial advantage; it's entirely free". Do not
  sweep for them.
- Contractions throughout. "isn't", "you'll", "doesn't".
- Italics and bold for mid-sentence emphasis: "an *emulated* HSM", "you **must** specify". This is his emphasis
  mechanism, not decoration.
- Motivation before mechanism. Why the reader should care comes before how the thing works, often as its own early
  section.
- Honest concession in the same breath as the claim: "This is useful for learning and understanding but it is not an
  actual HSM." "Using EV certificates isn't for everyone, it's expensive. However..." Never strip the concession to
  strengthen the pitch.
- Flat confident assertions with no hedging: "Without a doubt the biggest benefit of an HSM is that it is a physical
  piece of hardware."

## Doc register

Applies to documentation sites, guides, references, quickstarts, README prose, and any `docs/` content.

Samples:
- `https://raw.githubusercontent.com/openziti/ziti-doc/10ef29d8ebdcc834a088da0d9d3323caeeda108e/docfx_project/ziti/quickstarts/hsm-overview.md`
- `https://netfoundry.io/docs/openziti/learn/identity-providers/`

Rules:

- **No sentence fragments at all.** Every sentence is complete. The punchy fragment drumbeat belongs to the blog
  register and reads as broken here.
- **Definition first.** Name the subject and say what it is before anything else. "A hardware security module (HSM) is a
  physical piece of equipment which is designed specifically to protect cryptographic keys." "An Identity Provider (IdP)
  is a system that manages and authenticates the identity of users."
- **"Why" earns its own early section**, placed before any how-to. The literal heading `## Why an HSM` is the pattern.
- **"We" is the project, "you" is the reader.** "We have included a couple of quickstarts." "You will want to go to the
  OpenSC Project." Hold both steady.
- **Prose paragraphs under H2 headings**, not stacks of bullets. Bullets appear for genuine lists (prerequisites,
  supported clients, steps), not as a way to avoid writing paragraphs.
- **No punchy one-liners, no rhetorical flourish.** Explanatory, patient, and plain.
- Structure that recurs: what the thing is, why you would want it, what it takes to enable it, then pointers to the
  specific guides.

## Blog register

Applies to blog.openziti.io posts and anything with a byline and an opinion.

Samples:
- `https://blog.openziti.io/openziti-drinks-its-own-champagne`
- `https://blog.openziti.io/signing-executables-from-github-actions`

Rules:

- **First person narrator who tells you what he tried.** "I wanted to use AWS since that's where all our dev-related
  tooling was already." "Looking around the internet, for a long time, the only cloud-friendly tooling example I could
  find was a great blog from Sudara, but it leveraged Azure exclusively." The dead ends stay in. This is the one place
  the doc-humanizer "archaeology" rule must be suspended, because the narrative of what he tried IS the content.
- **Fragments as punches, and only after a complete sentence.** "Only authenticated and authorized identities get
  access. Period. No VPN. No bastion host." A fragment doing the work of a sentence on its own is a defect.
- **Rhetorical questions and flat dismissals.** "why wouldn't you?" "No 'are you on the right network' nonsense."
- **TL;DR at the top** of longer posts. **Pull-quotes** mid-article for emphasis.
- Ends with the project's standard "Share the Project" call to action. That block is boilerplate, leave it alone.

## What he rejects, stated plainly

He has rejected these in review, so they are known defects rather than guesses:

- Doc voice inflation: connective tissue, section intros that announce what the section will say, closing summaries.
- A fragment standing in for a sentence. "Or another company." was rejected hard.
- Abstraction before the concrete case. Give the situation, then the principle drawn from it.
- Restating one idea twice inside a single sentence.
- Any header that announces itself rather than the content, such as "## The one sentence".
