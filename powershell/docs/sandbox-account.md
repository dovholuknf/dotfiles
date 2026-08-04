# sandbox-account.ps1

A small, generic tool that confines a Windows account to read-only on the directory trees you name, while
letting it keep write access to an explicit allow-list of paths. It turns a broad, inherited write grant into a
scoped policy for one account. It ships in `powershell/onpath/`, so it is on `PATH` and runs by name.

## The problem it solves

On a shared drive it is common for a broad principal, by default `NT AUTHORITY\Authenticated Users`, to hold an
inherited `Modify` grant at the drive root. That grant flows down to every file and folder, so every account can
write everything. Convenient, and also a cross-account risk: if a low-trust account can write a script that a
high-trust account later runs, the low-trust account gets code execution as the high-trust one.

The fix is to stop relying on the blanket grant and instead say, per account: read everywhere, write only here.

## How it works (Windows ACL inheritance in four lines)

- A child inherits ACEs from its parent. A grant on a drive root with `(OI)(CI)` reaches every descendant.
- `icacls <dir> /inheritance:d` stops inheritance at `<dir>` and copies the currently-inherited ACEs onto
  `<dir>` as explicit ones, so Administrators, SYSTEM, and Users are preserved but the set is now editable.
- Removing the broad principal from `<dir>` (with `/T` for the whole subtree) drops its write. Descendants
  inherit `<dir>`'s new ACL, which no longer grants it.
- A later `/grant <account>:(OI)(CI)(M)` on a specific path re-adds write for exactly that account, exactly
  there.

The script does those steps for you, in the right order, for each tree and each write path.

## Parameters

| Parameter | Meaning |
| --- | --- |
| `-Account` (required) | The account to confine, for example `HOST\agent`. |
| `-Tree` (required) | One or more trees to bring under the policy. The broad principal is removed from these. |
| `-WritePath` | Zero or more paths where the account keeps write. Granted `Modify` (or `-Permission`). |
| `-OwnerUser` | Optional. Granted `Full` on each tree, for when the owner is not a local administrator. |
| `-BroadPrincipal` | The over-broad principal to remove. Default `NT AUTHORITY\Authenticated Users`. |
| `-Permission` | The icacls permission granted on each `-WritePath`. Default `(OI)(CI)(M)`. |
| `-Apply` | Execute. Without it the script prints the plan and changes nothing. `-Apply` also needs elevation. |

## Examples

Dry run, showing what confining an agent account to two trees, writable only under its worktrees, would do:

```
sandbox-account.ps1 -Account "HOST\agent" -Tree "D:\git","D:\worktrees" -WritePath "D:\worktrees"
```

Apply it (from an elevated shell), also letting the agent write a folder it authors inside a repo:

```
sandbox-account.ps1 -Account "HOST\agent" -Tree "D:\git","D:\worktrees" `
    -WritePath "D:\worktrees","D:\git\org\repo\agent-area" -Apply
```

If the owner account is not a local administrator, grant it Full at the same time:

```
sandbox-account.ps1 -Account "HOST\agent" -Tree "D:\git" -WritePath "D:\worktrees" `
    -OwnerUser "HOST\owner" -Apply
```

## Safety

- Dry run by default. It prints the exact `icacls` commands and changes nothing until you pass `-Apply`.
- `-Apply` refuses to run unless the shell is elevated.
- Idempotent. Re-running converges to the same state.
- It touches only the trees you name. It does not modify the drive root or any other account.
- It warns about any `-Tree` or `-WritePath` that does not exist, so a typo does not silently do nothing.

## Verify

After applying, check a file deep under a tree. The broad principal should be gone and the account should show
read only, unless the file is under a write path:

```
icacls "D:\git\org\repo\some\file"
```

## Undo or loosen

To return a tree to normal inheritance from its parent (which restores the broad grant if the parent still has
it):

```
icacls "D:\git" /reset /T
```

Or re-run the tool with the broad principal added back to the write list for that account.

## Assumptions and limits

- The account reads through `BUILTIN\Users:(RX)`, which `/inheritance:d` preserves. If your account is not in
  `Users`, add a read grant for it on the trees.
- The owner keeps access through `BUILTIN\Administrators`, or through `-OwnerUser`.
- This is filesystem ACLs only. Network credentials such as API tokens are not constrained by it. If an account
  holds a write-scoped token, it can still reach the remote regardless of these ACLs.
