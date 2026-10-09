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
  PR bodies and commits are lowercase. Round 3 showed lowercase to an outside user reads fine too. Mixed casing is
  what reads wrong.
- **Round 2: 3 of 5.** After the split, a "fewest words" rule and a "vague over specific" rule, Clint picked the draft
  three times and called one of the other two a tossup. The writer model also changed, from the session default to
  Sonnet, and he recognized one of his originals.
- **Round 3: 4 of 5, on the old rules.** The writer read the rule files from a worktree that had been reset after the
  edits moved to main, so it ran on the round 1 rules with Sonnet. In one task Clint was sure the draft was his. So
  the jump from round 1 came from the writer model or the tasks, not from the rule edits. Check which rule files a
  writer actually read before crediting the rules.
- **His old text is not always the target.** In round 3 he picked the draft over his own words four times. His
  reaction: "whhjhaaat -- that's f***ing nuts". The goal is text he would ship today, and some of what he wrote years
  ago, which trains the model as "good", he would now reject.
- **Round 4: Discourse, 0 of 4, every draft "good" or "fine".** He found his own text each time by a habit the rules
  didn't name: the same greeting for every first-time poster, quoting each point of a long post and answering it
  underneath, more words and hand-holding for learners, and a typo. Discourse is its own register. It is a learning
  forum, so it is the one place he writes more words, not fewer.
- **Clean the originals before showing them.** A typo told him which side was his. So do greetings he uses every
  time. Drop any pair where a fixed habit gives the answer away, or teach the writer the habit first.
- **The score passes but does not rank.** In rounds 2 and 3 the score matched his pick three times out of five each
  time. In round 2 every text scored 0.85 or higher. In round 4 it matched all four picks, on Discourse posts it had
  never trained on. In round 1 it passed two drafts he rejected. Held-out pair accuracy said 96%. Real picks
  are the eval that matters.
- **Length beats the model on reactions.** On replies he approved or complained about, the model scores AUC 0.54 to
  0.56 and "shorter is better" scores 0.62 to 0.66.
- **Ask the rewrite, and get the rule.** Each "why" in a pick named a rule nobody had written down: bullets for a
  squash commit with several changes, list the changes that look unrelated in a PR body, "< 60" over "within a
  minute", no aside wedged in before the payoff ("I gave it a full blog post I wrote, start to finish, and got 0.02").
- **A rule gets applied wherever it can be.** Pointed at the terse register for a code-comment walk, an agent
  lowercased "FIPS" because the first terse rule is "lowercase". Clint called it dumb. The model lowercases its input,
  so a case-only change never moves the score either. Scope each rule to the text it was learned from.

## Explaining a score

Rewriting a blog section one point at a time, a paragraph failed at 0.31 and nothing said why. The agent regenerated
it blind: guess a fix, score five variants, keep the best. That works, but it is slow and wastes tokens. The goal is a
check that tells a harness what to change, so it gets to a pass in one or two tries.

- **The model is linear, so a score splits exactly.** `clint score -why` adds up each word's weight, its share of the
  character n-grams, and the shape tokens, and the parts sum to the logit. It shows what moved the score.
- **Word lists were not useful.** The top words pulling a paragraph down were "the", "a", "it", "i" and ".". The top
  words pulling it up were topic words like "openziti" and "issue". Neither tells a writer what to change. Clint read
  them and said so. They stay behind `-why` for debugging the model.
- **Read the evidence before blaming the model.** The function words looked like the model punishing grammar, and so
  punishing his blog prose. Retrained with his blog held out, it passed 115 of 120 of his blog paragraphs, mean 0.93.
  The paragraph that scored 0.06 came from an agent-written draft, not from him. The model passes his prose. It fails
  LLM prose that only has the grammar.
- **What actually moved the score was shape.** The 0.31 paragraph went to 0.84 with fewer, longer sentences joined by
  "but" and "which", and contractions. That is what a harness can act on.
- **Score a sentence by removing it.** One sentence is too short for this model to score on its own, which is why
  paragraphs under 40 characters are skipped. Scoring the paragraph again without each sentence keeps the context and
  still names the sentence that drags it down.
- **Compare shape to the author's norm.** Sentences per paragraph, words per sentence and contractions, measured
  against his own paragraphs of the same register, give the writer a target instead of a guess.
- **The norm and the model disagreed.** His blog paragraphs have a median of 2 sentences of 15 words and almost no
  contractions. Rewriting a 0.76 paragraph to that shape dropped it to 0.62 and 0.52. The model accepts that shape
  from him, so shape is not what it reacts to in a draft. Shape stats describe; they do not predict the score.
- **Drag points at content too.** On a passing paragraph, the sentence whose removal helps most was the one carrying
  the point. Drag is shown only for failing paragraphs, and the fix is a rewrite of that sentence, not a delete.
- **Named style features barely separate him from an LLM.** Contractions, comma splices, ellipses, smileys, fragments,
  tech tokens, sentence length and the rest were measured per paragraph (`C:\temp\clint-style\measure-style.ps1`). No
  single one passed 0.68 AUC, against 0.99 for the n-gram model. The best were sentence length and comma splices on
  blog prose, and em dashes on chat, which lint already catches. They would add little as model inputs.
- **The teacher's rewrites don't look like him.** The same measurement showed the teacher's rewrites, the largest
  source of "Clint" examples, have the fewest contractions (0.7 per 100 words, his text has 1.7 to 3.4), the most
  fragments (16% of sentences, his 3 to 11%) and the shortest sentences (11.5 words, his about 16). The model learns
  that shape as his.
- **Down-weighting the teacher did not fix ranking.** Ten clear picks from the bake-offs (`pick-eval.ps1`): every
  weighting, from teacher rewrites at full weight to zero, scored the picked side higher 5 times of 10. That is a coin
  flip, and the same 5 each time. Down-weighting only cost pair accuracy (97.5% to 68.8%) and reaction AUC. The model
  tells his text from an LLM's. It cannot tell which of two texts that both sound like him is better. That needs his
  preferences as training data: grill, rw: and bake-off picks, not more LLM-versus-Clint examples.

## Ops

- **`curl -o NUL` in Git Bash makes a real file named NUL.** Windows then can't delete or move the folder. Remove it
  from bash with `rm`.
- **A background process started in a folder pins that folder.** Rename it after the process exits.
