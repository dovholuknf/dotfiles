# clint: lessons learned

What worked, what didn't, and why, in the order it was found. The blog post draws from this file.

## The label is the whole game

- **Prompts vs assistant replies learned the wrong thing.** Clint's typed prompts against assistant text scored 0.995
  holdout AUC and was useless. Prompts command and replies explain, so it learned register. A clean rewrite of an LLM
  reply scored 0.01, and Clint's own doc paragraph scored 0.22. A high AUC only says the classes separate, not that
  they separate on the thing you care about.
- **Lowercasing input was right.** Clint types in lowercase. Without it, an LLM passes by dropping capitals. Lowercased
  LLM text still scored as LLM.
- **Real reactions are too few and too noisy.** Of 6,494 typed prompt/reply pairs in the transcripts, 163 drew a
  style complaint and 215 an explicit approval. Many complaints are about content, not style. Every model scores
  about 0.6 AUC on them, level with a "shorter is better" baseline. They stay as an eval and a small extra signal.
- **Pairs fixed it.** Rewrite a real reply under the /clintify rules and train on original vs rewrite. Same content,
  two styles, so the only thing left to learn is style. Held-out pair accuracy reached 94-96%.

## Data hygiene

- **Most of the transcript data isn't prose.** About 2.4 GB of transcripts hold both sides, mostly tool calls, tool
  output and thinking blocks. Clint's typed text is 12 MB (`history.jsonl`).
- **Not every "user" turn is the user.** Hooks, skills, agent relays, coordinator messages and pasted briefs all
  arrive as user turns. The fix is to keep only prompts that also appear in `history.jsonl`.
- **Ask before assuming who wrote something.** PR bodies from 2025 on were assumed to be LLM drafted and used as
  negatives. Clint wrote all of them. Those pairs were deleted.
- **Hold out pairs whole,** and keep any held-out reaction out of the pairs too, or the eval leaks.
- **A held-out set of the target author's own writing is the best sanity check.** It showed what was over-learned.

## The teacher

- **The teacher's habits become the model's idea of good.** Haiku first dropped articles ("Daemon started in a claude
  session"). Untreated, the model would learn telegraphic English as Clint's style. The prompt now demands full
  grammatical sentences.
- **A local 30B model invents and drops.** Qwen3-Coder 30B on a 12 GB card added "Started run." when the reader runs
  it, added offers and Open Questions blocks, dropped constraints like "never in the repo", and collapsed whole replies
  to "Done.". Hard limits in the prompt fix most of it, and a filter drops the rest. The filter rejects rewrites
  under a fifth of the original's length, a "Done." the original never said, and any rewrite that still fails lint.
- **Claude-nostic means the teacher is a URL.** synth speaks the OpenAI chat API, so ollama, llama.cpp's server or
  vLLM all work. The trained model and the checker never need a network.

## Shape confounds

- **Authored text is short, LLM negatives were long.** Adding Clint's blog and GitHub paragraphs as positives taught
  "one short paragraph = clint", and a short LLM reply scored 0.67. Splitting both sides of each pair into
  paragraphs fixed it (0.13).
- **Whole-document scores punish length.** A full blog post scored 0.02. Documents with three or more paragraphs are
  now rated by their average paragraph.
- **Marketing copy is a blind spot.** Nothing in chat transcripts looks like it, so the model passes it. Lint catches
  the vocabulary ("seamlessly"). Lint and model cover different failures, which is why `check` runs both.

## Lint

- **A phrase in quotes is mentioned, not used.** Without that exception, a post about banned phrases fails its own
  lint.
- **Keep code, inline code and URLs out of it.** `--flag` is not a dash.

## Testing the writer

The checker is a means. The goal is an LLM that writes text Clint would ship. The test is blind: a fresh agent that
never saw the originals writes from the facts alone, and Clint picks between its draft and his own text, A or B in
random order. Each original is removed from a copy of the training data first, and `clint` scores both sides with a
model trained on that copy.

- **Round 1: 0 of 5.** Clint picked his own text every time and rejected both drafts that had no original. His
  reasons were the same each time: too many words and too specific. "the random pick used the endpoint count, not the
  candidate count" lost to "use the proper container when selecting model list size".
- **One register rule was wrong.** voice-clint said text under his name is all lowercase. That holds for chat with
  colleagues. His replies to outside users are sentence case, thank the reporter, show the fix and close the issue.
  PR bodies and commits are lowercase. Splitting the one register into three fixed it.
- **Round 2: 3 of 5.** After the split, a "fewest words" rule and a "vague over specific" rule, Clint picked the draft
  three times and called one of the other two a tossup. The writer model also changed (Sonnet), and he recognized one
  of his originals, so the jump is not all the rules.
- **The score passes but does not rank.** In round 2 every text scored 0.85 or higher and the score matched his pick
  three times out of five. In round 1 it passed two drafts he rejected. Held-out pair accuracy said 96%. Real picks
  are the eval that matters.
- **Length beats the model on reactions.** On replies he approved or complained about, the model scores AUC 0.54 to
  0.56 and "shorter is better" scores 0.62 to 0.66.
- **Ask the rewrite, and get the rule.** Each "why" in a pick named a rule nobody had written down: bullets for a
  squash commit with several changes, list the changes that look unrelated in a PR body, "< 60" over "within a
  minute", no aside wedged in before the payoff ("I gave it a full blog post I wrote, start to finish, and got 0.02").

## Ops

- **`curl -o NUL` in Git Bash makes a real file named NUL.** Windows then can't delete or move the folder. Remove it
  from bash with `rm`.
- **A background process started in a folder pins that folder.** Rename it after the process exits.
