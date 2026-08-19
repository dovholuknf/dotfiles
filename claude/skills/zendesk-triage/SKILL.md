---
name: zendesk-triage
description: >
  Triage a NetFoundry Zendesk support ticket end to end: pull the ticket and every comment (internal
  included), summarize it into the working repo, enumerate and download attachments, hand the logs to the
  right analyzer, and produce a reply plan that separates what the logs prove from what is still the
  customer's claim. Invoke when the user gives a Zendesk ticket number or netfoundry.zendesk.com URL, says
  "read this ticket", "triage 16059", "summarize this ticket", "what's going on in this ticket", or asks how
  to answer a customer on one. It reads and analyzes; it never posts to the ticket.
---

# zendesk-triage

Read-only against Zendesk. Never post a comment, change status, or reassign — draft the reply as text and
let the user post it.

The `mcp__mcp-gateway__zendesk_*` tools do the fetching: `zendesk_get_ticket`, `zendesk_get_comments`,
`zendesk_download_attachment`. If they are not loaded, `ToolSearch` for them by name first. The Swifteq
Zendesk MCP server is a different, OAuth-gated path — ignore it unless the gateway tools are missing.

## What you are producing

Three artifacts, in this order. Do not skip to the third.

1. `ZENDESK-<id>.md` in the working directory — the ticket itself: who, what, the reconstructed timeline,
   what support already said and asked for, open technical questions, and an attachment inventory.
2. `<id>-analysis.md` in the working directory — the log findings, from whichever analyzer fits the bundle.
3. A reply plan in chat — what to tell the customer, what to ask them, what to fix internally, and what to
   retract.

Attachments go to `C:\temp\support\nfsupport\<id>\` (bare ticket number, no `zd-` prefix), never into the
repo. Extracted log trees go to the session scratchpad — they hold identity material.

## 1. Pull everything, including the internal comments

```bash
# ticket metadata, then every comment - do NOT pass public_only
```

Call `zendesk_get_ticket` and `zendesk_get_comments` for the id. **Never use `public_only`.** The internal
comments are where the value is: the engineer's own timeline, pasted controller logs the customer never sees,
the escalation link, and the hypothesis you are being asked to test. On a live ticket the private analysis is
usually more detailed than anything sent to the customer.

Read the tags. `severity_2`, `1hr_response`, and an `intent__*` tag tell you the promised urgency and how the
ticket was classified — a classification that is sometimes wrong and worth correcting.

## 2. Inventory the attachments before downloading anything

List every attachment with file name, size, and which comment it came from. Then classify:

- `YYYY-MM-DD_HHMMSS.zip`, 50 KB–5 MB — a **ZDEW feedback bundle**. Hand to `debug-ziti-desktop-edge-win`.
- A zip of timestamped zips — an aggregated bundle, same skill, one pass per capture.
- A bare `ziti-edge-tunnel` log or a Linux/macOS tunneler bundle — the `ziti-edge-tunnel` log analyzer.
- Any image over ~15 KB — likely a console or settings screenshot. Worth reading; often it is the customer's
  actual evidence and it contradicts or narrows their prose.
- `image001.png`-style files under ~15 KB — email-signature noise. Never download.

Report the inventory and **ask which to download** rather than pulling everything. Then download with
`zendesk_download_attachment` into the staging dir, giving screenshots a descriptive name rather than the
Zendesk one (`edge-routers-console.jpg`, not `2026-08-10 10_31_47-Cloud Ziti_ Edge Routers — Mozilla
Firefox.jpg`).

Read the screenshots yourself. A console screenshot showing five routers "Offline" in a status column while
every row is `PROVISIONED` and green is a status-reporting defect on our side, not the outage the customer
believes they are looking at — and that distinction changes the entire reply.

## 3. Hand the logs to the analyzer, then do the ticket-level work the analyzer cannot

The bundle skill covers one machine's logs. These checks span the ticket and are yours:

### Correlate the client log against the controller log

Support usually pastes controller lines into an internal comment. Line them up by UTC timestamp. Expect the
controller to see a router leave **before** the client does — the client only notices when its latency probe
goes unanswered, which is tens of seconds later. That gap is normal SDK behavior, not a client defect, and it
gets misreported as one.

The question that matters is not who noticed first but **how long the far end was actually gone**. A client
retrying a router the controller itself will not accept for 68 minutes is behaving correctly, and no client
restart can shorten that.

### Distinguish a machine event from an infrastructure event

In the rolled client logs, two shapes mean opposite things:

- **Every router drops within a second or two and all return in 5–15 s** — a local network event on that
  machine. Benign. Say so and move on.
- **One router drops and stays gone for many minutes while the others are untouched** — infrastructure. This
  is the reportable one.

### Look for the same shape on earlier days

The rolled logs usually predate the reported incident by several days. Search them for the same signature. Two
single-router outages of near-identical duration on different days is a far stronger lead than anything in the
incident window alone, and it reframes the cause from "transient blip" to "recurring operation."

**Version strings date maintenance.** When the router that vanished comes back running a newer build than its
peers, that outage was an upgrade. When an identically-shaped outage ends with **no** version change, suspect
a failed or rolled-back one — and ask ops directly instead of accepting a latency-spike theory.

### Audit what support already told the customer

Read every public comment as a claim to verify. Any statement the logs do not support must be retracted
explicitly in the reply plan, named as a line to withdraw. Two recurring offenders:

- **IPC `EPIPE` errors** described as "system or network instability." They are almost always the desktop UI
  disconnecting from the tunneler's event socket — cross-check the UI log for a `UI started` line between the
  EPIPE timestamps. Presenting them as instability sends the customer chasing their own hardware.
- **"They restarted the tunneler."** Check `System Boot Time` in `systeminfo.txt` against the service-stop
  timestamp. A stop, a full machine reboot, and a manual service start are three different actions with three
  different implications, and the ticket will describe them as one.

### Confirm the diagnostics support asked for actually happened

List every request made to the customer (raise log level, recapture before restarting, send a directory
listing) and check the logs for whether it was done. Reporting "TRACE was never enabled, so the question we
asked is still unanswered" stops the team from re-analyzing the same bundle and is often the most actionable
line available.

## 4. Test the subject line as a claim

The ticket subject is the customer's words, not a finding. State plainly whether the logs corroborate it.

Split it into the parts that leave separate evidence:

- The failure the customer saw — usually the part with **no** log line at all.
- The remediation they performed — nearly always provable from lifecycle banners and boot time.
- Whether the remediation is what restored service — nearly always **unprovable** from a single bundle, and
  routinely asserted anyway.

Two reasons the failure leaves no trace, and they need different follow-ups: the client ran at INFO so
dial-level detail was never written, or the dial succeeded and the data stalled past a dead terminator, which
produces no client-side error. Say which you cannot rule out and name the artifact that would separate them.

Then find the one question whose answer discriminates the hypotheses, and put it at the top of the reply. For
a restart-fixed-it ticket that question is almost always: **did access come back when you restarted, or
closer to the time the infrastructure recovered on its own?** If the latter, the restart was coincidence and
the outage is the whole story.

## 5. Write the reply plan

Three buckets, kept apart:

- **The customer's pain** — what broke for them, what we know about why, and the question we need answered.
- **Ours to fix quietly** — status mis-reporting, mis-set alerting, a console showing Offline for healthy
  routers. Name it internally; do not hand the customer a defect list they did not ask about.
- **Answerable without the customer** — anything ops or the controller can settle. Do these before asking
  the customer for more. Asking a severity-2 customer for logs to answer a question our own controller
  already knows reads as stalling.

## Hard rules

- **Separate observation from inference, in writing.** Quote the log line, then say what you think it means.
  A support engineer relaying your words to a customer must be able to tell which is which. Mark inferences
  as inferences.
- **"No evidence of X" always carries its coverage caveat.** A bundle collected minutes after a restart
  cannot speak to what happened after the capture, and the analyzer prunes logs on startup.
- **Never paste identity files, session tokens, certificates, or full controller URLs** into a report that
  might be forwarded. Quote the smallest fragment that makes the point. Service names, hostnames, and
  identity names are fine when the finding needs them and the report stays internal.
- **Do not narrow the ticket to the part you solved.** If two symptoms are tangled — a client that cannot
  recover and a console that lies about router state — carry both to the end and say which is which.
- Prefer being useful over being complete: a healthy-system section is three lines, not three paragraphs.
