---
name: andrewify
description: Reformat long, low-context LLM output into Andrew's preferred presentation, emitted as Mattermost-safe markdown. Invoke with /andrewify on a pasted block of model output.
disable-model-invocation: true
---

# andrewify

Reshapes pasted LLM output into the form Andrew reads. This is a **formatting pass, not a research pass**.

## Hard rules

1. **Never invent.** No fact, name, number, date, quote, citation, `file:line`, or symbol that is not in the paste. If the source is vague, stay vague. Do not resolve, verify, or extend it.
2. **Never pad.** If the paste says one thing, the output is one line. A format fixes shape, never volume.
3. **Preserve substance, drop performance.** Keep every claim, decision, caveat, and unknown. Drop preamble, restatement, "what this means", closing summaries, and any sentence whose job is to show that work happened.
4. **Keep the source's hedging.** If the paste hedged, keep the hedge. Never promote a hedge to a fact, and never add one that was not there.

## Shape

**One topic** — no docket. State it in one or two lines and stop.

**Two or more topics** — an executive brief line, then the docket, then one detail section per topic.

Executive brief: one sentence naming what the whole paste is about and its verdict. No prefix, no formatting, sits alone above the docket. It is the line someone reads instead of the message. Never more than two lines, and never a summary of the sections below it.

```
A 2.0 router refuses a process posture check that a 1.6 controller
passes, because posture evaluation moved to the router.
```

Docket line: a per-message letter prefix plus a number, a hyphen, then a short memorable title. No evidence, no paths, no line numbers.

```
A1 - Migration created, conflicts remain
A2 - Auth refresh path never exercised
A3 - Benchmark numbers came from a different build
```

Detail section: the docket line reproduced exactly, blank line, then **at most 3 lines** of statement. Over the cap means cut words or cut the topic, never a fourth line.

```
A2 - Auth refresh path never exercised

No test covers refresh after expiry. The source flags this as untested,
not as broken.
```

Order topics by what needs a decision first, then what is broken or unresolved, then what was tried or ruled out, then everything else. Ordering is the only thing that gate decides here. Andrew's own reports drop completed work entirely, but a paste is someone else's material, so nothing is deleted for being uninteresting, it just sinks to the bottom.

**Evidence.** A section may carry one fenced block of material quoted from the paste, a log excerpt, an error, a command, a table. It does not count against the 3-line cap, and it may sit before, between, or after the statement lines, wherever the reader needs it. Quote it verbatim. Two candidate blocks in one section means the section is really two topics, or one of the blocks is not evidence.

## Always

1. **Number every list item.** Never bullets. Numbers make items referenceable in a reply.
2. **Tables go in a code fence, space-aligned.** Pipe tables collapse in some of his clients. A fenced table always renders.
3. **Every ASCII or text diagram gets a mermaid translation directly below it**, in its own fence. Mattermost renders mermaid in recent versions and degrades to a readable code block where it does not.
4. **Code-path walkthroughs** open with the answer, then a one-line chain, then one scannable fragment line per actor. No narrative paragraphs.
5. **Prose written in Andrew's own voice carries no dashes of any kind.** Instructional or explanatory text may keep em dashes.

## Never

1. No parenthetical editorial callouts. Not "(the important part)", not "(note this)". Emphasis comes from structure and ordering.
2. No bold for decoration, no Title Case headings, no decorative emoji.
3. No "Challenges" / "Key Takeaways" / "Conclusion" section created by shape rather than content.
4. No upbeat send-off that states nothing.
5. No meta-commentary about the reformatting. No "here is the cleaned-up version", no note on what was cut.

## Tells to strip while rewriting

1. Puffery and broader-trend framing.
2. Vague attribution: experts argue, industry reports, it is widely known.
3. AI vocabulary: crucial, delve, landscape, pivotal, showcase, tapestry, testament, underscore, vibrant, robust, seamless.
4. Negation fragments: "not just X, it's Y", and clipped trailing negations standing in for a clause.
5. Forced triads and false ranges: a pair padded to three, "from X to Y" across no shared scale.
6. Synonym cycling: one thing renamed across successive sentences. Take the source's first term and hold it.
7. Filler: in order to, due to the fact that, has the ability to, could potentially.
8. Hollow constructions: tacked-on `-ing` clauses, elaborate verbs standing in for `is` or `has`.
9. Exact counts of a collection where the count carries no argument. Name the collection instead.

## Mattermost constraints

1. Fenced code blocks, inline code, bold, italic, strikethrough, block quotes, links, ordered and nested lists all render.
2. No raw HTML. It is stripped.
3. Nested list indentation must be consistent, and nesting stays at two levels or fewer.
4. Headings render but read as shouting in a chat message. Prefer the docket over `#` headings. Use a bold label if a section marker is genuinely needed.
5. Prose wraps on its own in every client, so never hard-wrap it. Fenced content does not reflow, so keep a fenced block no wider than its content needs.

## Delivery

The output is a message for Mattermost, not for this terminal. Hand it over as a single fenced block so it can be copied in one action. Use a four-backtick fence, since the output carries three-backtick fences of its own. Nothing goes outside that fence, no lead-in and no closing note.

## Procedure

1. Read the whole paste. List the distinct topics it actually contains.
2. Drop everything that is performance rather than content.
3. One topic, no docket and no brief. Two or more, write the executive brief, then the docket, then the sections.
4. Convert lists to numbered, tables to fenced and aligned, diagrams to ASCII plus mermaid.
5. Strip the tells above without changing any claim.
6. Reread against the 3-line cap and the never-invent rule. Cut, do not append.
7. Emit the whole message inside one four-backtick fence.

## Worked example

Input, a narrated investigation writeup:

````
How this was found

I ran two quickstarts side by side on one Windows box, v1.6.19 on one pair of ports and v2.0.2 on
another, and configured them with the same commands. Each got a service hosted by its own router, so a
dial can actually complete, and a single process-multi posture check: AllOf, Windows, one path, no
hashes and no signer fingerprints. With nothing to compare but the path and whether the process is
running, there is very little left that can go wrong.

I enrolled one identity from each controller into the same ziti-edge-tunnel, started the process, and
dialed both services. The 1.6.19 dial returned data. The 2.0.2 dial was refused:

posture check proc-check failed due to error(s): all values must be valid have at least one failure,
have: Path:"C:\\Windows\\System32\\notepad.exe" Hashes:"74e6c105...", failed for:
[the state did not match because os types do not match, given , expected: Windows,
expected: OsType:"Windows" Path:"C:\\Windows\\System32\\notepad.exe", given: <nil>]

The have: clause is the part that matters. The router did receive the process posture, with the right
path and a hash, so the client is reporting what it was asked for. What the router does not have is OS
posture, and it fails the check on that. Create any OS check on the same policy and the process check
starts passing, because that is what makes the SDK begin collecting OS data. The process check itself
never changed.

The client explains the version difference in its own log:

WARN ziti_channel_update_posture() ch[9] edge router does not support posture updates
INFO ziti_pr_send_bulk() ztx[8] ERs do not support receiving posture responses

A 1.6 router tells the SDK it does not handle posture, so the SDK posts to the controller and the
controller evaluates. A 2.0 router accepts posture over the channel, so the router evaluates instead.
Same client, same data, different evaluator, different answer.
````

Output:

````
A process posture check that passes on 1.6.19 is refused on 2.0.2, because posture evaluation moved from the controller to the router and the SDK only collects OS data when an OS check exists on the policy.

```
P1 - 2.0.2 refuses a process posture check that 1.6.19 passes
P2 - The router evaluates posture in 2.0, the controller in 1.6
P3 - Adding any OS check to the policy makes the process check pass
P4 - Repro is two quickstarts side by side on one box
```

P1 - 2.0.2 refuses a process posture check that 1.6.19 passes

Same client, same posture data. The 1.6.19 dial returned data. The 2.0.2 dial was refused.

```
posture check proc-check failed due to error(s): all values must be valid have at least one failure,
have: Path:"C:\Windows\System32\notepad.exe" Hashes:"74e6c105...", failed for:
[the state did not match because os types do not match, given , expected: Windows,
expected: OsType:"Windows" Path:"C:\Windows\System32\notepad.exe", given: <nil>]
```

The `have:` clause shows the router did receive the process posture with the right path and a hash, so the client is reporting what it was asked for. What the router does not have is OS posture, and it fails the check on that.

P2 - The router evaluates posture in 2.0, the controller in 1.6

A 1.6 router tells the SDK it does not handle posture, so the SDK posts to the controller and the controller evaluates. A 2.0 router accepts posture over the channel and evaluates itself. Same client, same data, different evaluator, different answer.

```
WARN ziti_channel_update_posture() ch[9] edge router does not support posture updates
INFO ziti_pr_send_bulk() ztx[8] ERs do not support receiving posture responses
```

P3 - Adding any OS check to the policy makes the process check pass

An OS check on the same policy is what makes the SDK begin collecting OS data. The process check itself never changed.

P4 - Repro is two quickstarts side by side on one box

Windows, v1.6.19 and v2.0.2 on separate port pairs, configured with the same commands. Each has a service hosted by its own router and one process-multi check: AllOf, Windows, one path, no hashes, no signer fingerprints. One identity from each controller enrolled into the same ziti-edge-tunnel.
````

What the pass did, and did not do:

1. The narration went. "How this was found", "there is very little left that can go wrong", "the part that matters" carry no claim.
2. Evidence stayed. Both log excerpts and the full error text are content, not performance, and each sits under the topic it supports.
3. Nothing was resolved. The source never says why the SDK gates OS collection on an OS check, so neither does the output.
4. Repro detail survived as its own topic rather than an opening paragraph, because someone reproducing needs it and nobody else reads past P1.

