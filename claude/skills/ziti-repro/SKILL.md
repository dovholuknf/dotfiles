---
name: ziti-repro
description: Reproduce and debug an OpenZiti bug with paired quickstarts across LTS lines. Invoke when the user says
  "repro this", "reproduce the bug", "stand up a quickstart to test X", "does this happen in 1.6", wants behavior
  compared across ziti versions, or wants a regression bisected between LTS lines. Produces per-version repro md files
  and, at the end, a network-free Go test.
---

# ziti-repro

Reproduce an OpenZiti bug so a maintainer believes it. Two versions, isolated stacks, working-then-broken.

## 1. Resolve the version labels first

Never hardcode versions. Read https://github.com/openziti/ziti/blob/main/RELEASE_POLICY.md#openziti-lts-strategy or run
`gh release list --repo openziti/ziti --limit 20` to resolve the current labels, then take the newest patch of each
line.

As of 2026-08-11: Latest Development 2.1, Active LTS (N) 2.0, Maintenance LTS (N-1) 1.6, EOL 1.5 and below.

Stand up **two** quickstarts: Active LTS and Maintenance LTS. One version proves nothing. The A/B across LTS lines is
what makes the report credible — it separates "bug" from "always worked that way".

## 2. Port scheme from the version

Strip the dots, zero-pad to 4 digits, prefix `1` → controller port. Router port = controller port + 1.

| version | stripped | padded | controller | router |
|---------|----------|--------|------------|--------|
| 1.6.19  | 1619     | 1619   | 11619      | 11620  |
| 2.0.2   | 202      | 0202   | 10202      | 10203  |

Two stacks never collide, and the port tells you which stack you are looking at.

## 3. Isolate everything per stack

Separate `--home` and separate `ZITI_CONFIG_DIR`. The config dir isolates both the CLI identity cache and the
trusted-CA store — required, because both controllers advertise `localhost` with different self-signed CAs.

```powershell
$env:ZITI_CONFIG_DIR = "C:\temp\ziti-repro\cfg1619"
```

```bash
export ZITI_CONFIG_DIR=/tmp/ziti-repro/cfg1619
```

Use a *separate* admin `ZITI_CONFIG_DIR` for scripted/agent access so it never fights the human's interactive shell. A
second login invalidates nothing, but the cached token ages out and the confusion costs an hour.

## 4. Build a fully working example FIRST, then break it

This is the core rule. Get an end-to-end dial returning real data before introducing the thing under test. Then the
diff between working and broken is one or two `ziti edge` commands — and that diff is the entire bug report.

Per stack (1.6.19 shown):

```bash
ziti edge quickstart --home /tmp/qs1619 \
    --ctrl-address localhost --ctrl-port 11619 \
    --router-address localhost --router-port 11620 \
    -u admin -p admin

export ZITI_CONFIG_DIR=/tmp/cfg1619
ziti edge login localhost:11619 -u admin -p admin -y

ziti edge create config mgmt-intercept intercept.v1 \
    '{"protocols":["tcp"],"addresses":["mgmt-1619.ziti"],"portRanges":[{"low":443,"high":443}]}'
ziti edge create config mgmt-host host.v1 '{"protocol":"tcp","address":"localhost","port":11619}'
ziti edge create service mgmt-svc --configs mgmt-intercept,mgmt-host
ziti edge create identity zdew-1619 -a clients -o zdew-1619.jwt
ziti edge create service-policy mgmt-dial Dial --service-roles '@mgmt-svc' --identity-roles '#clients'
ziti edge create service-policy mgmt-bind Bind --service-roles '@mgmt-svc' --identity-roles '@router-quickstart'
```

Requirements that make the dial actually succeed:

- The service must be **hosted**: `intercept.v1` + `host.v1` configs, a Bind policy naming the router identity, and the
  router in `tunnel: host` mode (the quickstart router already is).
- Verify hosting with `ziti edge list terminators`. A service with no terminators fails for a reason unrelated to the
  bug and will waste an hour.
- Router identity name differs by line: `router-quickstart` on 1.6.x, `router-instance-1` on 2.0.x. Get it from
  `ziti edge list identities`.
- Point `host.v1` at something that answers — the controller's own API port is ideal:
  `curl -sk https://mgmt-1619.ziti/edge/client/v1/version` returns version JSON that names the version, so success is
  unambiguous and it proves *which* stack answered.
- Enroll the JWT in the tunneler (ziti-edge-tunnel / ZDEW). For a CLI identity, `ziti enroll identity <jwt>`; confirm
  the exact form with `ziti enroll --help` on the line under test.

Then break it with the smallest possible change:

```bash
ziti edge create posture-check process-multi proc-check AllOf Windows 'C:\Windows\explorer.exe' -a posture
ziti edge update service-policy mgmt-dial --posture-check-roles '#posture'
```

## 5. Traps

- Intercept hostnames must not collide across stacks. One tunneler holding both identities resolves a shared name to
  whichever stack registered it first, and you silently test the same stack twice. Suffix per stack.
- Numeric TLDs do not resolve on Windows. `mgmt.1619` fails; use `mgmt-1619.ziti`.
- Posture/session state is cached per api-session on the router. A client that sent posture earlier keeps sending it, so
  a check added mid-session can pass for a stale reason. Toggle the identity off/on (or restart the tunneler) for a
  clean read; tear the whole lab down and rebuild for the final proof run.
- Enrollment JWTs expire in about 30 minutes. If enrollment fails, check that first.
- `curl -s` hides connection errors. Use `-v` when a dial returns nothing.
- A passing posture check on an unhosted service still fails, with `has no terminators`. That message is the
  posture-PASSED signal, not a posture rejection. Do not confuse the two.

## 6. Where the verdict lives, and which plane owns it

In 2.0.x the router evaluates posture from its own cache; the controller may hold nothing.

Controller's view — `GET /edge/management/v1/identities/<id>/posture-data`. Auth differs by line:

```bash
# 1.6.x: legacy session id cached at .token
TOKEN=$(jq -r '.. | .token? // empty' "$ZITI_CONFIG_DIR/ziti-cli.json" | head -1)
curl -sk -H "zt-session: $TOKEN" \
    "https://localhost:11619/edge/management/v1/identities/$ID/posture-data" | jq .

# 2.0.x: OIDC access token cached at .apiSession.oidcAccessToken
TOKEN=$(jq -r '.. | .apiSession?.oidcAccessToken? // empty' "$ZITI_CONFIG_DIR/ziti-cli.json" | head -1)
curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:10202/edge/management/v1/identities/$ID/posture-data" | jq .
```

Router's view of policy and config — `ziti fabric inspect router-data-model` (fans out through the controller). There
is no posture key on the router's inspect surface, so runtime posture state is not inspectable. The client log
(ziti-edge-tunnel / ZDEW) carries the actual rejection text and is the only window into the router's verdict.

## 7. Capture the repro as two md files, one per version

`<version>.repro.md` each: the working config, the one command that breaks it, the observed error. Commands and outcome
only. No narration.

~~~markdown
# v1.6.19 repro

```bash
<setup commands>
```

Enroll `zdew-1619.jwt`, then `curl -sk https://mgmt-1619.ziti/edge/client/v1/version` returns version JSON.
Dial succeeds.

Add the check:

```bash
<the breaking command>
```

Dial STILL succeeds.
~~~

## 8. Endgame: a network-free Go test

Once the behavior is understood, the most convincing artifact is one Go test that calls both code paths — controller
evaluator and router evaluator — on the same input and shows opposite results, no network involved. Put it beside the
repro md files and name the two entry points explicitly in the test's doc comment.

## Teardown

```bash
# stop the background quickstart processes, then:
rm -rf /tmp/qs1619 /tmp/cfg1619 /tmp/qs2020 /tmp/cfg2020
```

Also remove the test identities from the tunneler. Stale identities in a tunneler are a common source of confusing
later runs.
