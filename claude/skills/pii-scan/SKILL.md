---
name: pii-scan
description: >
  Scan a file, directory, pasted block, or the last response for PII and secrets before you share it: emails, names,
  phone numbers, public IPs, MACs, hostnames/FQDNs, Windows user paths, and credentials (JWTs, private keys, API
  tokens, bearer tokens, enrollment tokens, .ziti identities). Reports findings grouped by category, secrets first,
  with location and a MASKED snippet. Redaction is opt-in and writes a scrubbed COPY. Invoke with /pii-scan, or when
  the user says "scan for PII", "any PII in here", "scrub this before I share it", "check for secrets". It never
  uploads or sends anything anywhere.
---

# pii-scan

Find PII and secrets in content so it can be scrubbed before sharing. Detection first, redaction only on request.

## Safety (non-negotiable)

- Local only. NEVER upload, post, email, or send the content OR the findings to any external service, tool, or network
  call. This skill exists to keep sensitive data on the machine.
- Read-only by default. Redaction happens only when the user explicitly asks, and writes a NEW scrubbed copy. Never
  overwrite the original unless the user says so in that request.
- Never print an unmasked secret in the report. Mask every match.

## Target

- A path (file or directory), a pasted block, or "the last response".
- Directory: scan recursively; skip `.git`, `node_modules`, build output, and binaries unless asked.
- Support bundles and logs (ZDEW feedback zips, ziti-edge-tunnel logs) are dense with customer PII: names, emails,
  public IPs, hostnames, identity names, and enrollment tokens. Expect it.

## What to look for

Run these with `rg` / Grep, then read a little context around each hit to judge it.

Credentials and secrets (report FIRST, highest sensitivity):
- Private-key blocks: `-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----`
- JWT / enrollment token: `eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}` (and `.jwt` files, `.ziti`
  identity files, which embed certs and keys)
- Known token shapes: `github_pat_`, `ghp_`/`gho_`/`ghs_`, AWS `AKIA[0-9A-Z]{16}`, Slack `xox[baprs]-`, Atlassian
  `ATATT`, OpenAI-style `sk-[A-Za-z0-9]{20,}`, Google `AIza[0-9A-Za-z_-]{35}`
- Assignments: `password=`, `passwd=`, `api[_-]?key=`, `secret=`, `token=`, `Authorization: Bearer ...`
- Generic high-entropy: a long base64/hex string assigned to a key-looking name

Network and host:
- IPv4 `\b(?:\d{1,3}\.){3}\d{1,3}\b` -- then DOWNGRADE to low/context: RFC1918 (`10.`, `172.16-31.`, `192.168.`),
  loopback `127.`, link-local `169.254.`, CGNAT `100.64.0.0/10`. Public IPs are the real finding.
- IPv6
- MAC `\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b`
- Hostnames / FQDNs, especially `*.netfoundry.io`, `*.production.netfoundry.io`, ziti controller/router IDs, and
  customer network names

Personal:
- Email `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`
- Phone (loose) `\+?\d[\d\s().-]{7,}\d`
- Windows user path `[A-Za-z]:\\Users\\[^\\\r\n]+` -- the `<user>` segment is the PII
- Person / org names: heuristic only. Flag proper-noun names near `customer`, `requester`, `assignee`, `contact`, or
  in signatures. Low confidence -- list these separately, do not treat as certain.

## Reduce false positives

- Version numbers look like IPs. Placeholders (`example.com`, `127.0.0.1`, `<redacted>`, `xxxx`, `foo@bar.com`) are
  not PII. Well-known public IPs (`8.8.8.8`, `208.67.222.222`) are low-risk. UUIDs and commit SHAs are not secrets.
- Mark private-range IPs, loopback, and documented example values as low/context, not findings.

## Report

- One-line header: `N findings (K credentials, M network, P personal, Q low-confidence)`.
- Group by category, most sensitive first: credentials, then network, then personal, then low-confidence names.
- Per hit: category, `file:line` (or offset for pasted text), a MASKED snippet (first and last few chars only, e.g.
  `github_pat_11ALB…<redacted>`), and a confidence.
- Never print a full secret. If the whole value is short, mask all but the first 2 chars.

## Redaction (opt-in only)

- Only when the user asks ("redact", "scrub it", "fix it").
- Write a scrubbed COPY next to the source (`<name>.scrubbed<ext>`). Never overwrite the original unless the user
  explicitly says overwrite in that request.
- Replace each category with a stable placeholder: `<EMAIL>`, `<IP>`, `<MAC>`, `<JWT>`, `<TOKEN>`, `<PRIVATE_KEY>`,
  `<USER>`, `<HOST>`, `<PHONE>`, `<NAME>`.
- After writing the copy, re-scan it and confirm it comes back clean. Report what was replaced and where the copy
  landed.
