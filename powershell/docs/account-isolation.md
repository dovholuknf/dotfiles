# Account isolation and hardening (clint vs claude)

This box runs two Windows accounts. `clint` is the interactive human. `claude` is an unprivileged account that
hosts claude-code agent instances. The goal of the split is containment: a misbehaving or compromised agent,
running as `claude`, must not read clint's data or run code as clint.

This document records what is already isolated, the one gap found in a scan, and the hardening that closes it.

## Verified isolation (scanned 2026-08-02, run as the claude account)

Reproduce this audit any time, read-only, with `powershell/onpath/audit-account-acls.ps1`, run as the account you
are checking. It reports risky groups and privileges, cross-account reads, writable system locations, and blanket
write grants on the trees you name. `sandbox-account.ps1` is the fix for what it finds.

- `claude` is a standard local user at Medium integrity. It is a member of only Everyone and Authenticated Users.
  It is NOT in Administrators, Backup Operators, or Power Users.
- `claude` holds no dangerous privileges: no `SeImpersonatePrivilege`, `SeBackupPrivilege`, `SeRestorePrivilege`,
  `SeDebugPrivilege`, or `SeTakeOwnershipPrivilege`. Only the benign defaults (change-notify, timezone, shutdown).
- clint's profile (`C:\Users\clint`) denies `claude` both read and directory listing.
- System locations deny `claude` write: `C:\`, `C:\Program Files`, `C:\Windows`, `C:\Windows\System32`.

That posture is sound. The account itself has no local privilege-escalation primitives, and the interactive
user's profile is opaque to it.

## The blanket grant vs a designed sandbox

Sharing `D:` between the two accounts is intentional. The collaboration is the point: both accounts edit the
dotfiles repo and work in the worktree tree. The issue is that the sharing is a blanket grant, not a scoped
policy. `icacls D:\` shows `NT AUTHORITY\Authenticated Users:(OI)(CI)(M)`, inherited to every child on the drive.
Because `claude` is an authenticated user, it can modify everything on `D:\`, confirmed by write probes:

- clint's git clones under `D:\git\...` (all writable).
- every worktree under `D:\worktrees`.
- the PowerShell code clint's shell runs at every launch: `powershell/shared/common-tools.ps1`, both profiles,
  `wt-themes*.ps1`, and everything on `ON_PATH` (`powershell/onpath/*`).

### Why it matters

clint's profile dot-sources those scripts on every shell launch, and clint runs `gwt` and other on-PATH tools
constantly. A rogue `claude` can append a line to `common-tools.ps1` (or any sourced or on-PATH script) and it
runs as clint the next time clint opens a shell. The same holds for any build or run step clint executes inside a
clone or worktree that `claude` can write. This is the single bridge from the contained agent back to the human.
Everything else on the box is locked down. This is not.

Secondary: `C:\ProgramData` root is also writable by `claude`. Lower severity, but worth an audit, since some
programs load code from there.

## Recommended hardening

This is codified as the generic `powershell/onpath/sandbox-account.ps1` (explained in `sandbox-account.md`). For
this box, run it elevated as clint:

```
sandbox-account.ps1 -Account "<host>\claude" `
    -Tree "D:\git","D:\worktrees" `
    -WritePath "D:\worktrees","D:\git\github\dovholuknf\dotfiles\claude" `
    -Apply
```

It dry-runs by default (prints the plan) and changes nothing until you pass `-Apply`, which also requires an
elevated shell. `claude` cannot change these ACLs itself, which is why this is an administrator action. It assumes
clint keeps Full through `BUILTIN\Administrators`. If clint is not a local administrator, add
`-OwnerUser "<host>\clint"`.

The result: `claude` keeps Read across `D:` but writes only its worktrees (which include the session ledger and
watch log) and `dotfiles\claude`, the content it authors. Everything else, including clint's clones and
`dotfiles\powershell`, becomes read-only to `claude`.

### The one decision: who owns the shell tooling

With the command above, `dotfiles\powershell` is read-only to `claude`, which closes the shell-injection path. The
tradeoff: `claude` can no longer self-edit the PowerShell tooling (common-tools, profiles, themes, gwt). Decide who
owns that code. To keep `claude` editing it (co-development), add `dotfiles\powershell` to `-WritePath`, and accept
that this re-opens code execution as clint. To keep the isolation, leave it out and have `claude` propose tooling
changes for clint to apply.

### Secondary: ProgramData

Audit `C:\ProgramData` subdirectories and remove `claude` write where an elevated process could load code from
them. This is separate from the `D:` policy above.

## Residual trust assumptions

- Shared worktrees: if both accounts write under `D:\worktrees`, clint must not execute code from a worktree that
  `claude` can write. Giving `claude` a dedicated worktree root that clint never runs from removes this.
- The claude GitHub token: filesystem ACLs do not constrain it. If `CLAUDE_GH_TOKEN` carries write scope, `claude`
  can push over the network regardless of these ACLs. Keep it read-only.

## Not yet scanned

- A full writable-surface sweep: `accesschk -uwqs "<host>\claude" C:\` from Sysinternals lists every path this
  account can write.
- Services and scheduled tasks whose binaries or working directories `claude` can write, which would be a path
  from `claude` to SYSTEM. Sysinternals `accesschk -uwcqv "<host>\claude" *` covers services.
