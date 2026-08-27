# Defender exclusions for a claude-code host box

Windows Defender real-time scan is the single largest performance cost on a box that runs claude-code hard.
Two paths dominate, and both are local, trusted, high-churn content that Defender gains almost nothing by
scanning. Excluding them drops sustained `MsMpEng` (Antimalware Service Executable) CPU and the heat that
comes with it.

## What Defender was burning time on

Captured with `New-MpPerformanceRecording` + `Get-MpPerformanceReport` on the SG4 dev box while claude ran.

1. `C:\Users\claude\.claude\hooks\set-session-state.ps1` took 1853 ms in a single AMSI real-time scan. That
   hook fires on every prompt-submit, stop, notification, and session start and end. A first-seen script
   triggers a Defender cloud reputation lookup (MAPS), which is the network round-trip behind the ~1.8 s. A
   locally-cached trusted script scans in about 25 ms.
2. The claude transcript files under `C:\Users\claude\.claude\projects\...*.jsonl` were scanned OnClose every
   time claude appended a message. That runs continuously during active use and was the bulk of the sustained
   Defender CPU.

Everything else in the trace was under about 50 ms, so these two paths are the whole story.

## The fix (run once per box, elevated)

```powershell
# the hook scripts that fire every turn (kills the ~1.8s AMSI cost)
Add-MpPreference -ExclusionPath 'C:\Users\claude\.claude\hooks'
# claude's transcripts, scanned on every close as it writes them
Add-MpPreference -ExclusionPath 'C:\Users\claude\.claude\projects'
# verify
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
```

Adjust the account home if the box runs claude under a different user than `claude`.

## Scope note

Exclusions lower protection on those paths. Keep the exclusion this narrow. Both paths are the agent's own
hook scripts and its own append-only logs, neither executed as a download. Do NOT exclude the pwsh binary or
all of `.claude`, because claude runs arbitrary code and AMSI should stay live for that.

## Related

- `powershell/clear-defender.ps1` removes every exclusion (a reset). Re-add the two paths above after running
  it.
- `powershell/local-llm/wsl-disk-maintenance.md` is the other standing box-maintenance runbook.
