# Building a local LLM host

How to turn a fresh Windows machine into a headless model server, and point a workstation at it.

`setup-llm-host.ps1` does all of it. This document explains what it does and why, so the decisions are
reviewable rather than buried in a script.

## Verdict, August 2026

The hardware worked. A GMKtec EVO-X2 (Ryzen AI Max+ 395, 128GB unified, split 64/64) ran Qwen3-Coder
30B-A3B at 1200 t/s prompt and 95 t/s generation, and held four concurrent agent sessions at 20 t/s
each. None of the offload gymnastics an 8GB card needs. It went back anyway.

**The blocker is model quality, not speed.** Given four small, precisely-specified edits to PowerShell
files it had just read, the 30B at Q4 produced three broken results:

- a missing comma in a param block, so the script would not parse at all
- a `-Restore` branch reading a variable twelve lines before its assignment, so it never worked
- a command line built as a single string and invoked with `&`, which broke the script's existing
  function while adding the requested switch

All three parse-looked correct, documented themselves accurately, and failed only when run. An earlier
task came out genuinely correct, so the rate is somewhere under half — and the cost is not the rate, it
is that reviewing the output means running all of it.

**The harness matters more than expected.** OpenCode sends roughly 9,900 tokens of system prompt and
tool definitions per turn, and its compaction rewrites conversation history, which invalidates the
server's prefix cache. Worst observed turn: 78 seconds of prompt reprocessing for four seconds of
generation. Pi, whose system prompt is under 2,000 tokens, cut the cold start from 22s to 1.7s and held
turns under 1.5s. Same box, same model. If you retry any of this, start with Pi.

**Faster hardware would not have changed the conclusion.** An RTX 5090 is roughly 5-7x on both axes for
models under 32GB, which makes the wrong answers arrive sooner. The case for unified memory is running
70-120B models a 32GB card cannot load at all — a bet on open models in that class getting good enough,
not a capability available today.

What follows is the runbook, which stands on its own: it builds any Windows LLM host, and the traps are
hardware-independent.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `setup-llm-host.ps1` | the new host, elevated | Everything below, in phases. |
| `add-ssh-host.ps1` | the workstation | Writes the client `~/.ssh/config` entry. |
| `start-llm.ps1` | either | Starts `llama-server` with tuned flags. |

## Quick path

On the new machine, in an elevated shell:

```powershell
.\setup-llm-host.ps1 -WhatIf          # see what it would do
.\setup-llm-host.ps1                  # prompts for settings, Enter accepts each default
```

The OpenSSH install needs a reboot before the service exists. The script stops and says so; restart and
run it again. Every phase is idempotent, so the second run skips what is already done.

Reuse the same answers on the next machine:

```powershell
.\setup-llm-host.ps1 -SaveAnswerFile .\host.json    # first machine
.\setup-llm-host.ps1 -AnswerFile .\host.json        # every machine after
```

Settings resolve in this order: command line, answer file, prompt, default. `-NonInteractive` skips the
prompting for unattended runs.

Individual phases, for repair work:

```powershell
.\setup-llm-host.ps1 -Phase Runtime,Model
```

---

## Phases

### Account

Creates a local account that owns the model server.

`New-LocalUser` leaves the account in no groups at all — that is `net user /add` behaviour, not the
cmdlet's. The account still logs in and still has Users-level access, because the `Users` group itself
contains `NT AUTHORITY\Authenticated Users`. Group membership is therefore not a lever on a standalone
machine; file permissions are the only control that applies. The Harden phase is built around that.

`-PasswordNeverExpires` is deliberate. A headless box that locks you out on day 42 is a bad afternoon.

### Ssh

Installs the OpenSSH server capability and sets it to start automatically.

Two things to expect:

- **It is slow.** OpenSSH Server is a Feature on Demand, fetched from Windows Update rather than staged
  locally. Minutes, and longer while the machine is pulling its first round of updates.
- **It needs a reboot.** `Add-WindowsCapability` returns `RestartNeeded : True` and means it. Until the
  restart, `Start-Service sshd` fails with "Cannot find any service with service name 'sshd'", which
  reads like the install did nothing.

Setting the service to Automatic is easy to skip and produces a box that stops answering SSH after its
next reboot.

### Network

Creates the inbound rule if the capability install did not, then checks the adapter profile.

A rule scoped to Private does nothing while the adapter is classified Public, and the resulting
connection timeout is indistinguishable from the service being down. This is the most common cause of
"SSH is installed and running and I cannot connect".

### Pwsh

Installs PowerShell 7 from the MSI.

Not winget. `winget install --id Microsoft.PowerShell` installs the MSIX package, which lands as a
per-user app-execution alias under `WindowsApps` — a zero-byte reparse point that only resolves in the
owning user's context, and therefore useless as a machine-wide SSH shell. `Test-Path` on the real
install directory returns False while `Get-Command pwsh` reports a path, which is a confusing pair of
answers. Asking winget for the MSI with `--scope machine --installer-type msi` returns "No applicable
installer found".

`msiexec /qn` returns immediately while the install continues in the background, so the script waits on
the process rather than checking straight after.

### Shell

Points `HKLM:\SOFTWARE\OpenSSH\DefaultShell` at `pwsh.exe`. Without it, SSH sessions land in `cmd.exe`.
Applies to the next connection; no service restart.

### Runtime

Installs llama.cpp from the GitHub release zip, picking CUDA on NVIDIA and Vulkan everywhere else.
Vulkan covers AMD and Intel without a vendor toolkit, including Strix Halo's integrated Radeon.

Not winget here either: `winget install ggml.llamacpp` installs the Vulkan build regardless of GPU and
drops it in the invoking user's `%LOCALAPPDATA%\Microsoft\WinGet\Packages\`, with only that user's PATH
updated — invisible to the service account.

On NVIDIA the matching `cudart` zip unpacks into the same directory, because those DLLs must sit beside
`llama-server.exe`. A CUDA 13.x build runs against a 13.x driver under minor-version compatibility.

`llama-server --version` does not prove the GPU backend loaded. `--list-devices` does, and the script
prints it:

```
CUDA0: NVIDIA GeForce RTX 4070 Laptop GPU (8187 MiB, 7068 MiB free)
```

### Model

Downloads a GGUF with `curl -C -`, so no Python or HuggingFace CLI is needed and an interrupted
download resumes.

If you use `hf download --local-dir` by hand instead: while it runs the destination file does not
exist. `hf` writes to `<local-dir>\.cache\huggingface\download\*.incomplete` and moves it into place on
completion, so starting the server mid-download gives a "No such file or directory" that looks like a
typo.

Sizing: pick the quant against **free RAM**, not total. Weights must stay resident, and a machine that
pages mid-generation is worse than one running a smaller quant.

### Harden

Confines the service account.

**The ceiling, stated first.** There is no chroot. Any account that logs in needs read and execute on
`C:\Windows` and `C:\Program Files` to run a shell, load DLLs, and complete the login. Remove that and
the result is an account that cannot log in, not a confined one. Windows OpenSSH's `ChrootDirectory`
covers SFTP sessions only.

This constrains a well-behaved process. It does not contain a hostile one that finds a local privilege
escalation. When the boundary has to hold, run the workload in a VM or a Hyper-V container — unified
memory hardware has the headroom for it.

What it does:

- **Strips group membership** beyond `Users`. `Get-LocalGroupMember` throws for an entire group
  containing any unresolvable SID, common on an OEM image, so failures fall back to parsing
  `net localgroup` rather than being swallowed into "no memberships found" for what might be an
  administrator.
- **Denies every non-system fixed drive** at the root, with inheritance. This is the largest and least
  obvious hole on any machine that has a second drive: a freshly formatted volume grants `Users` full
  control at its root, inherited all the way down.
- **Denies each other user profile** explicitly. Default ACLs already do this; an explicit deny survives
  a parent folder being loosened later.
- **Denies write to `C:\ProgramData`**, read intact. Several subtrees there grant `Users` write, which
  is a persistence path. Read has to stay or shell startup breaks.

Deny ACEs beat allow ACEs regardless of order, which is what makes this hold when inherited permissions
change later. It is also why `-AllowPath` re-opens the whole ancestor chain: a deny at a drive root
beats an allow nested underneath it.

What stays reachable, unavoidably:

- `C:\Windows` and `C:\Program Files`, read and execute.
- The account's own profile.
- The network. No file permission restricts outbound connections; that needs a firewall rule, and
  Windows Firewall can scope outbound rules by user.

`-DenyInteractiveLogon` in `harden-localai.ps1` denies console and RDP logon, leaving SSH as the only
way in. SSH public-key auth produces a network-type logon, so it survives. Leave it off until key auth
is proven, and keep a separate administrator account for recovery.

### Report

Prints the client-side pieces: the `~/.ssh/config` entry, the key-install command, the `llama-server`
launch line, and the harness provider JSON.

---

## Client side

### SSH config

`add-ssh-host.ps1` writes it. Two directives are load-bearing:

```
Host sgx2
    HostName sgx2.local
    User localai
    AddressFamily inet
    IdentityFile C:/Users/clint/.ssh/id_ed25519
    IdentitiesOnly yes
```

**`IdentitiesOnly yes`** — offer only this key. A wildcard `Host *` block earlier in the config pins
whatever identity it names, so the client offers that key and never tries the right one. The failure is
`Permission denied (publickey)` with a correctly installed `authorized_keys`, which sends you hunting
server-side ACLs for a client-side problem. `ssh -v` names the key it actually tried.

**`AddressFamily inet`** — force IPv4. mDNS answers a `.local` name with link-local IPv6 addresses ahead
of the A record, and a `fe80::` address carries an interface scope only meaningful on the machine that
generated it. Pinging the name *from the host itself* succeeds, which makes this look like a workstation
problem rather than an address-selection one.

Prefer the `.local` name over an IP when the host is on DHCP. A DHCP-suffixed name such as
`sgx2.<your-dhcp-suffix>` does not resolve off-box; `sgx2.local` does.

Do not paste a here-string into an interactive prompt to build this. The terminator only closes the
block when `'@` sits at column zero, and the shell's indentation folds into the literal. Also write it
as ASCII: PowerShell 5.1's default UTF8 adds a BOM that OpenSSH reads as part of the first directive.

### Installing the public key

```powershell
$key = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()
ssh localai@<host> "mkdir .ssh & echo $key >> .ssh\authorized_keys"
```

`.Trim()` is load-bearing. `-Raw` keeps the trailing newline, which splits the remote command in two:
`echo <key>` prints the key to your terminal and a stray `>> .ssh\authorized_keys` runs on its own. It
looks like it worked and nothing is written. If the key appears in your terminal, that is what happened.

`&` rather than `&&` because that is cmd.exe on the far end until the Shell phase runs: `mkdir` fails
harmlessly when `.ssh` exists and the `echo` still runs.

Verify with an explicit check rather than a plain login, which would silently fall back to a password:

```powershell
ssh -o PreferredAuthentications=publickey <host> whoami
```

### Harness

`%USERPROFILE%\.config\opencode\opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": {
        "qwen3-coder-30b-a3b": { "limit": { "context": 32768, "output": 8192 } }
      }
    }
  }
}
```

`context` must equal the server's `--ctx-size`. OpenCode's own documentation shows 128000 in this
example; copy that against a 32k server and the harness builds prompts four times larger than the
window.

There is no CLI flag for a provider baseURL. `OPENCODE_CONFIG_CONTENT` takes the same JSON inline for a
throwaway shell, but a provider must be defined somewhere before `-m provider/model` can name it.

---

## Measured results

`llama-bench -ngl 99 -p 4096 -n 128 -r 3`, same command on both machines.

| model | host | GPU | prompt t/s | generation t/s |
| --- | --- | --- | --- | --- |
| Qwen3-Coder 30B-A3B, UD-Q4_K_XL | SG4 | RTX 4070 Laptop, 8GB | 380.5 ± 6.3 | 25.3 ± 2.7 |
| Qwen3-Coder 30B-A3B, UD-Q4_K_XL | SGX2 | Radeon 8060S, unified | 1200.2 ± 6.5 | 95.3 ± 0.1 |
| Qwen3-Coder-Next 80B-A3B, UD-Q4_K_XL | SGX2 | Radeon 8060S, unified | 729.1 ± 9.6 | 47.8 ± 0.3 |
| Qwen3.8-27B dense, UD-Q4_K_XL | SGX2 | Radeon 8060S, unified | 261.8 ± 0.2 | 12.6 ± 0.0 |

Four things worth carrying forward.

**Mixture-of-experts suits this hardware; dense models do not.** The dense 27B loses on both axes to a
model three times its size. Generation speed tracks *active* parameters, and a dense model has no small
active slice — every token reads all 16.3GB. At 262 t/s prompt processing a 10k agent context costs 38
seconds before the first token, against 14 for the 80B.

**Unified memory removes the tuning problem, it does not merely relax it.** Strix Halo's Vulkan driver
reported 93GB free without any BIOS change, so nothing spills and no `--n-cpu-moe` sweep is needed.
The deviation tells the same story: ±0.1 on generation against ±2.7 on the 8GB card.

**A fixed UMA frame buffer can only cap what the driver already offers.** The shared allocation exceeded
what a 64/64 BIOS split would have provided, so setting one is not an improvement to chase.

**Doubling model size costs about half the throughput even at identical active parameters.** Both models
activate 3B parameters per token, yet the 80B runs at roughly half the 30B's rate. The router pulls
experts from a 46GB pool rather than a 16GB one, so this is memory bandwidth and cache locality, not
compute. Expect the same shape on any MoE: active parameters predict compute, total size predicts
bandwidth pressure.

**Kill every stray `llama-server` before benching, and do not trust `--list-devices` to tell you.** A
first run of the dense 27B measured 53 t/s prompt processing, a fifth of its real figure, because two
forgotten servers still held GPU memory. `--list-devices` reported 93GB free throughout, because it
counts shared system memory rather than free dedicated VRAM. Task Manager's *dedicated GPU memory*
figure showed 63.3 of 63.8 GB and was the accurate one. `taskkill /f /im llama-server.exe` first.

## Two traps

### Ctrl-C does not stop a remote server

Windows sshd does not deliver Ctrl-C to the remote process without a PTY. Interrupting a local `ssh`
session that started `llama-server` detaches you and leaves the server running.

Start remote servers with `ssh -t` so Ctrl-C propagates. Before any benchmark, confirm nothing is
holding the GPU:

```powershell
taskkill /f /im llama-server.exe
```

A stale server skews results badly and quietly — prompt processing drops several-fold. `--list-devices`
will not warn you, because its "free" figure counts shared system memory rather than free dedicated
VRAM. Task Manager's *dedicated GPU memory* is the honest number.

### A corrupt GGUF loads and runs at full speed

Symptom: fluent-looking multilingual token soup at normal throughput, even at temperature 0.

```
(EFFECTing onesCanBeConverted easily dàngRGBO_PIXELあるいsenal.Charting.Charting...
```

A GGUF with damaged tensor data still has a valid header and correctly shaped tensors, so it loads
without complaint and computes nonsense at full speed.

Hash the file first, before investigating anything else:

```powershell
Get-FileHash <model>.gguf -Algorithm SHA256 | Select-Object Hash
```

The alternative explanations — Vulkan backend, cooperative-matrix kernels, model architecture, a build
regression — each take an hour to rule out and all present identically. Garbage from both the CPU and
GPU backends, across two llama.cpp builds, means the file, not the code.

Prefer `hf download` over copying a model between machines. It verifies checksums and runs faster than
scp anyway: 118 MB/s against 35, since scp is single-threaded and bound by its own encryption. When a
download is interrupted, kill the process before writing to the same path — see the trap above.

## Tuning a VRAM-limited GPU

Skip this when the model fits in VRAM. It matters for mixture-of-experts models on a small card, where
attention and the KV cache live on the GPU and expert weights sit in system RAM.

**Tune with `llama-bench`, not by watching a single generation.** Repeated runs with a stated deviation
are the only way to see the effect, and on a GPU that also drives a desktop the noise from other
applications swamps a one-shot measurement.

```powershell
llama-bench -m <model.gguf> -ngl 99 -p 4096 -n 128 -r 3 --n-cpu-moe 32,36,40,44
```

Reference sweep, RTX 4070 Laptop (8GB VRAM, 64GB RAM), Qwen3-Coder 30B-A3B at UD-Q4_K_XL:

| `--n-cpu-moe` | prompt t/s | generation t/s |
| --- | --- | --- |
| 32 | 111.9 ± 3.0 | 16.2 ± 1.5 |
| 36 | 368.7 ± 14.5 | 21.6 ± 3.7 |
| **40** | **380.5 ± 6.3** | **25.3 ± 2.7** |
| 44 | 357.5 ± 12.3 | 24.5 ± 2.2 |

The cliff between 32 and 36 is the thing to know. Move too many expert layers onto the GPU and the
Windows driver silently spills to system RAM over PCIe instead of failing. Prompt processing drops 3.3x
and nothing reports an error — the symptom is generation decaying mid-response, which reads like noise.
**There is no clean OOM to tune against on Windows.** Tune by throughput.

`llama-bench` allocates a small context, so a large KV cache costs VRAM the sweep did not account for.
If generation decays under the real server configuration, raise `--n-cpu-moe` one step.

Three flags come out of this:

- **`--n-cpu-moe`** at the measured peak. Do not lower it chasing "more layers on the GPU".
- **`--load-mode none`** disables mmap. With experts on the CPU, mmap lets the OS fault expert weights
  in from disk mid-generation. Paying the full read at startup buys steady throughput.
- **`--parallel 1`** gives one slot. With the default of 4, consecutive turns land on different slots by
  LRU and re-process the entire system prompt.

That last flag matters more than it looks. An agent harness sends a large system prompt plus tool
definitions on every turn — OpenCode's is around 9.7k tokens. A cold "you alive" took 24.7 seconds, of
which 21.5 was prompt processing. One slot means the prefix caches and later turns skip to the new
message. Anything that fires a side request, such as session-title generation, can otherwise evict the
prefix mid-session and reintroduce the 21-second pause for no visible reason.

If prompt size is the floor, the harness is the lever: Pi's system prompt is under 1k tokens against
OpenCode's ~9.7k.

## Choosing the pieces

The harness and the engine are separate choices.

**Harness.** OpenCode is the default — terminal TUI, MIT, points at any OpenAI-compatible endpoint.
Goose and Pi are the alternatives; Pi's small system prompt is the reason to switch on constrained
hardware.

**Engine.** llama.cpp over Ollama for one reason: Ollama does not expose `--cpu-moe`. Without expert
offload a 30B MoE does not run on 8GB at all. vLLM or SGLang are the answer when there is VRAM to spare
and real concurrency to serve.

**Model.** Mixture-of-experts is what makes a 30B-class model viable on a small card — 3B active
parameters per token against 30B total.

`ninfer` exposes an Anthropic-compatible API, so Claude Code itself can point straight at it, but it
rejects any CUDA architecture other than `sm_120a`: RTX 5090 only.
