$rawInput = [Console]::In.ReadToEnd()
$json = $rawInput | ConvertFrom-Json

# Root-of-drive folders. C:\ grants Authenticated Users CreateDirectories, so nothing in Windows
# stops a non-elevated process making C:\whatever - the only guard is this one.
#
# Returns the first drive-root path in the text whose top-level directory does not already exist.
# An existing one (C:\Users, D:\worktrees) is not a new root folder and is left alone.
function Find-NewRootPath {
    param([string]$Text)
    if (-not $Text) { return $null }
    foreach ($m in [regex]::Matches($Text, '(?<![\w.])([A-Za-z]):[\\/]([^\\/:*?"<>|''`\s,;)]+)')) {
        $drive = $m.Groups[1].Value
        $seg   = $m.Groups[2].Value
        $top   = "${drive}:\$seg"
        if (Test-Path -LiteralPath $top) { continue }

        # An unquoted path with a space in it - C:\Program Files - arrives here truncated at the
        # space, so the segment looks like a folder that does not exist. Anything the root already
        # holds by that prefix means the real path is longer than what matched, not new.
        $existing = Get-ChildItem -LiteralPath "${drive}:\" -Directory -Filter "$seg*" `
                        -ErrorAction SilentlyContinue
        if ($existing) { continue }

        return $top
    }

    # The Bash tool's spelling of the same thing: /c/foo, /d/foo. A single-letter first segment is
    # what distinguishes it from an ordinary unix path, so /usr and /tmp do not match.
    foreach ($m in [regex]::Matches($Text, '(?<![\w./])/([a-zA-Z])/([^/\\:*?"<>|''`\s,;)]+)')) {
        $top = "$($m.Groups[1].Value):\$($m.Groups[2].Value)"
        if (-not (Test-Path -LiteralPath $top)) { return $top }
    }

    return $null
}

$rootBlock = "Do not create folders at the root of a drive. Put it under D:\tmp instead - that " +
             "directory exists and is the place for scratch, demo and test output that does not " +
             "belong in the project tree (build.claude/ or similar). This applies to a script's " +
             "default output path too: running the script is the same act as writing the files " +
             "directly, so change the default rather than passing an override."

if ($json.tool_input.command) {
    $newRoot = Find-NewRootPath $json.tool_input.command
    if ($newRoot) {
        @{
            decision = "block"
            reason   = "$rootBlock The path '$newRoot' does not exist, so this would create it."
        } | ConvertTo-Json -Compress
        exit 0
    }
}

if ($json.tool_name -eq "Write" -or $json.tool_name -eq "Edit" -or $json.tool_name -eq "NotebookEdit") {
    $newRoot = Find-NewRootPath $json.tool_input.file_path
    if ($newRoot) {
        @{
            decision = "block"
            reason   = "$rootBlock The path '$newRoot' does not exist, so writing this file would create it."
        } | ConvertTo-Json -Compress
        exit 0
    }
}

# Claude Code renamed the subagent tool from Task to Agent. Match both, or the gate goes dead.
if ($json.tool_name -in @('Task', 'Agent')) {
    # Redirect plain Claude subagents to real atrium sessions, so agent work is watchable
    # on the board and kept in history instead of being ephemeral. ON by default; set
    # ATRIUM_ONLY_SUBAGENTS=0 (or off/false/no) to allow normal subagents for a session --
    # the fan-out skills (review-panel, qa-review, pr-review, afk) need that. Fail-open:
    # pure string check, no external call.
    #
    # READ-ONLY HELPERS ARE EXEMPT. Explore and Plan spawn no board card and mutate nothing;
    # a doer using one to read the codebase is not the ephemeral-work problem this guards
    # against. They pass through even when the guard is on. log-subagent.ps1 still records the
    # start (type + description = the why) into state.log, so every one is visible in agent-log.
    # clint's decision 2026-09-21: allow read-only subagents inside doers, keep redirecting the rest.
    $subtype = "$($json.tool_input.subagent_type)".Trim().ToLower()
    $readonlyAgents = @('explore', 'plan')
    $g = "$env:ATRIUM_ONLY_SUBAGENTS".Trim().ToLower()
    if (($readonlyAgents -notcontains $subtype) -and $g -ne '0' -and $g -ne 'off' -and $g -ne 'false' -and $g -ne 'no') {
        @{
            decision = "block"
            reason   = "Plain Claude subagents are off here (ATRIUM_ONLY_SUBAGENTS). Run substantive agent work as a REAL atrium session instead, so it is watchable on the board and kept in history. HARD RULE, check FIRST: call the atrium-control MCP tool atrium_peers and count the running sessions YOU launched (sessions the user started do not count); if you launched 10 or more (the concurrency cap), do NOT launch another -- wait for one to finish or ask clint, do not spawn past the cap. Otherwise: (1) make/prepare the working directory first -- it must already exist; (2) call atrium_launch with cwd, a short title, a one-line why, and a FULL prompt containing the ENTIRE task (the new session inherits NONE of this conversation's context, so spell it all out); (3) use the returned card id with atrium_task / atrium_say to follow up. If a normal one-shot subagent is genuinely wanted this session, the user can set ATRIUM_ONLY_SUBAGENTS=0 and retry."
        } | ConvertTo-Json -Compress
        exit 0
    }
}

# Any tool that carries a shell command, not just the Bash tool. A PowerShell tool call
# (or any future shell tool) presents its command in tool_input.command too, and a git
# commit issued that way must hit the same policy -- gating on tool_name == "Bash" left a
# hole where `git commit` on a non-claude/* branch sailed through the PowerShell tool.
if ($json.tool_input.command) {
    $cmd = $json.tool_input.command

    # No Co-Authored-By trailer, ever. Catches it in git commit messages and gh pr bodies.
    if ($cmd -match 'co-authored-by') {
        @{
            decision = "block"
            reason   = "Never add a Co-Authored-By trailer to a commit message or PR description, and never suggest one. No attribution or co-author line of any kind, ever. This is absolute."
        } | ConvertTo-Json -Compress
        exit 0
    }

    # go build output goes to build.claude, never the repo's normal paths.
    if ($cmd -match '\bgo\s+build\b' -and $cmd -notmatch '-o\s+\S*build\.claude') {
        @{
            decision = "block"
            reason   = "go build must write to build.claude. Add -o build.claude/ (directory form works for ./... too)."
        } | ConvertTo-Json -Compress
        exit 0
    }

    # ---- git policy: claude works only on its own claude/* branches, and NEVER a remote ----
    # Read-only git (status, log, diff, show, remote, branch listing) always passes.
    #   push/pull/fetch          -> ALWAYS blocked (no git command reaches a remote)
    #   branch-naming verbs      -> the NAMED branch must start 'claude/'
    #     (branch create/delete/rename, 'checkout -b', 'switch [-c]')
    #   current-branch verbs     -> the CHECKED-OUT branch must start 'claude/'
    #     (commit, add, rebase, reset, restore, clean)
    # Anything on a non-claude/ branch, or any remote op, is handed back to the user.
    # Validated by claude/hooks/tests/test-git-guard.ps1 -- keep that green.
    function _GitBlock($why) {
        @{ decision = "block"; reason = $why } | ConvertTo-Json -Compress
        exit 0
    }
    $gitCwd = if ($json.cwd) { "$($json.cwd)" } else { (Get-Location).Path }

    # 0a. No creating/unsetting git aliases. An alias is a bypass: it can hide a blocked
    #     verb ('co'=checkout) or run a shell command ('!...'). Reads (--get/--list) pass.
    if ($cmd -match '\bgit\s+(?:-\S+\s+)*config\b' -and $cmd -match '\balias\.' -and
        $cmd -notmatch '--(get|get-all|get-regexp|list)\b') {
        _GitBlock "claude may not create or unset git aliases (an alias can hide a blocked verb or run a shell command). Hand it to the user."
    }

    # 0b. Resolve an alias in the subcommand position BEFORE the checks below, so an alias
    #     cannot smuggle a blocked verb past the text match. Expand up to 5 levels; a
    #     '!'-shell alias is arbitrary code and is blocked outright. Real verbs (commit,
    #     push, ...) are not aliases, so 'config --get' returns empty and nothing changes.
    $depth = 0
    while ($depth -lt 5 -and $cmd -match '\bgit\s+(?:-\S+\s+)*([A-Za-z][\w-]*)') {
        $sub = $Matches[1]
        $exp = ''
        try { $exp = "$(& git -C "$gitCwd" config --get "alias.$sub" 2>$null)".Trim() } catch { $exp = '' }
        if (-not $exp) { break }
        if ($exp.StartsWith('!')) {
            _GitBlock "git alias '$sub' is a shell alias ('!...') -- claude may not run it (arbitrary command). Hand it to the user."
        }
        $rest = ($cmd -replace ('^.*?\bgit\s+(?:-\S+\s+)*' + [regex]::Escape($sub) + '\b'), '')
        $cmd  = "git $exp$rest"
        $depth++
    }

    # 1. Remote ops: never, on any branch, with one exception: atrium's hub remote (hub forge
    #    design 5.3, wall 1). The whole command must be exactly one of
    #      git push hub <branch> | git push -u hub <branch> | git fetch hub
    #    (or the same with 'atrium-hub'), and every url and pushurl of that remote, after
    #    insteadOf rewrites, must start with this room's forwarder, <agent>/git/, where <agent>
    #    comes from atrium's daemon.json. No force, no '+' or ':' refspec, no extra flags, and
    #    no daemon.json means refused. The hub's pre-receive is the wall behind this one.
    if ($cmd -match '\bgit\s+(?:-\S+\s+)*(push|pull|fetch)\b') {
        $hubRemote = $null
        # [ \t], not \s: a newline would end the git command and start another.
        if ($cmd -match '^[ \t]*git[ \t]+push[ \t]+(?:-u[ \t]+)?(hub|atrium-hub)[ \t]+[A-Za-z0-9_][\w./-]*[ \t]*$' -or
            $cmd -match '^[ \t]*git[ \t]+fetch[ \t]+(hub|atrium-hub)[ \t]*$') {
            $hubRemote = $Matches[1]
        }
        $hubOk = $false
        if ($hubRemote) {
            $agent = ''
            try {
                # ATRIUM_LOCATION names this room's daemon.json when the machine runs more than one room.
                $dj = if ($env:ATRIUM_LOCATION) { $env:ATRIUM_LOCATION } else { Join-Path $env:LOCALAPPDATA 'atrium\daemon.json' }
                $agent = "$((Get-Content -LiteralPath $dj -Raw -ErrorAction Stop | ConvertFrom-Json).agent)".TrimEnd('/')
            } catch { $agent = '' }
            if ($agent -match '^http://127\.0\.0\.1:\d+$') {
                $urls = @()
                try {
                    Push-Location -LiteralPath $gitCwd
                    $urls += @(& git remote get-url --all $hubRemote 2>$null)
                    $urls += @(& git remote get-url --push --all $hubRemote 2>$null)
                } catch { $urls = @() } finally { Pop-Location }
                $urls = @($urls | Where-Object { "$_".Trim() })
                $hubOk = $urls.Count -gt 0
                foreach ($u in $urls) {
                    if (-not "$u".Trim().StartsWith("$agent/git/")) { $hubOk = $false }
                }
            }
        }
        if (-not $hubOk) {
            _GitBlock "claude never pushes, pulls, or fetches -- no git command may reach a remote. Hand it to the user. The one exception is atrium's hub remote: exactly 'git push hub <branch>', 'git push -u hub <branch>' or 'git fetch hub', and only when that remote points at this room's atrium forwarder."
        }
    }

    # 2a. checkout: allowed ONLY as 'checkout -b claude/*'. Plain 'git checkout <x>' is
    #     ambiguous with file restore, so it is blocked; use 'git switch' to move branches.
    if ($cmd -match '\bgit\s+(?:-\S+\s+)*checkout\b') {
        if ($cmd -match '\bcheckout\s+(?:-\S+\s+)*-[bB]\s+(\S+)') {
            if ($Matches[1] -notmatch '^claude/') { _GitBlock "claude may only create claude/* branches. '$($Matches[1])' is not one." }
        } else {
            _GitBlock "Use 'git switch claude/<branch>' to move branches. Plain 'git checkout' is blocked here (ambiguous with file restore, and claude stays on claude/* branches)."
        }
    }
    # 2b. switch: 'switch -c <n>' (create) or 'switch <n>' (move). Target must be claude/*.
    elseif ($cmd -match '\bgit\s+(?:-\S+\s+)*switch\b') {
        if ($cmd -match '\bswitch\s+(?:-c\s+)?(?:-\S+\s+)*([^\s-]\S*)') {
            if ($Matches[1] -notmatch '^claude/') { _GitBlock "claude may only switch to claude/* branches. '$($Matches[1])' is not one." }
        } else {
            _GitBlock "claude may only 'git switch' to a named claude/* branch."
        }
    }
    # 2c. branch: every branch-name argument (create/delete/rename) must be claude/*.
    #     No name args (a listing: 'git branch', '-a', '-r', '-v') passes.
    elseif ($cmd -match '\bgit\s+(?:-\S+\s+)*branch\b') {
        $after = ($cmd -replace '^.*?\bgit\s+(?:-\S+\s+)*branch\b', '').Trim()
        $names = @($after -split '\s+' | Where-Object { $_ -and ($_ -notmatch '^-') })
        foreach ($n in $names) {
            if ($n -notmatch '^claude/') { _GitBlock "claude may only create/delete/rename claude/* branches. '$n' is not one." }
        }
    }
    # 3. Current-branch verbs: the checked-out branch must be claude/*.
    elseif ($cmd -match '\bgit\s+(?:-\S+\s+)*(commit|add|rebase|reset|restore|clean)\b') {
        $verb = $Matches[1]
        $branch = ''
        try { $branch = "$(& git -C "$gitCwd" rev-parse --abbrev-ref HEAD 2>$null)".Trim() } catch { $branch = '' }
        # Mid-rebase HEAD is detached. The branch being rebased is in head-name
        # (rebase-merge for -m/-i, rebase-apply for the am backend).
        if ($branch -eq 'HEAD') {
            foreach ($dir in 'rebase-merge', 'rebase-apply') {
                $hn = ''
                try { $hn = "$(& git -C "$gitCwd" rev-parse --git-path "$dir/head-name" 2>$null)".Trim() } catch { $hn = '' }
                if ($hn -and -not [IO.Path]::IsPathRooted($hn)) { $hn = Join-Path $gitCwd $hn }
                if ($hn -and (Test-Path -LiteralPath $hn)) {
                    $branch = ((Get-Content -LiteralPath $hn -Raw) -replace '^refs/heads/', '').Trim()
                    break
                }
            }
        }
        if ($branch -notmatch '^claude/') {
            $where = if ($branch) { "current branch is '$branch'" } else { "no claude/* branch is checked out" }
            _GitBlock "claude may only '$verb' on a claude/* branch ($where). Switch to a claude/* branch, or hand the command to the user."
        }
    }

    if ($cmd -match '(^|;|\n)\s*cd\s+\S.*&&') {
        @{
            decision = "block"
            reason   = "Do not use compound 'cd /path && command' patterns. Run 'cd /path' as a standalone command first, then run subsequent commands without cd prefixes."
        } | ConvertTo-Json -Compress
        exit 0
    }

	if ($cmd -match '(^|;|\n)\s*git\s+((?:-C\s+\S+)|(?:.*--git-dir=\S+))') {
		@{
			decision = "block"
			reason   = "Do not use 'git -C <path>' or 'git --git-dir=<path>' patterns. Run 'cd /path' as a standalone command first, then run the git command normally."
		} | ConvertTo-Json -Compress
		exit 0
	}

	if ($cmd -match '(^|;|\n)\s*find\s+') {
		@{
			decision = "block"
			reason   = "Do not use 'find' in bash. Use glob patterns instead."
		} | ConvertTo-Json -Compress
		exit 0
	}

	# No perl. Matches perl invoked as the command (start, or after a pipe/compound),
	# not 'perl' inside a path/arg or words like 'perldoc'.
	if ($cmd -match '(^|;|\||\n|&&)\s*perl\b') {
		@{
			decision = "block"
			reason   = "Do not use perl. Use bash (or the dedicated file/search/edit tools) instead."
		} | ConvertTo-Json -Compress
		exit 0
	}

	# No python by default. Matches python / python3 / python.exe invoked as the command
	# (start, or after a pipe/compound), not 'python' inside a path or words like
	# 'pythonpath'. A nudge, not an absolute: rework in bash/pwsh, or ask if it's truly needed.
	if ($cmd -match '(^|;|\||\n|&&)\s*python3?(\.exe)?\b') {
		@{
			decision = "block"
			reason   = "Do not use python unless bash or PowerShell genuinely cannot solve the problem. Prefer bash, pwsh, or the dedicated file/search/edit tools. If python is actually required for this, say why and ask the user first."
		} | ConvertTo-Json -Compress
		exit 0
	}

	# Docker: forbid inline env-var prefixes; env must be passed via flags
	if ($cmd -match '^\s*([A-Za-z_]\w*=\S+\s+)+docker\b') {
		@{
			decision = "block"
			reason   = "Do not prefix inline env vars before docker (e.g. 'FOO=bar docker ...'). Pass env explicitly: 'docker run -e VAR=val', a compose block, or '--env-file'."
		} | ConvertTo-Json -Compress
		exit 0
	}
	
	# ';' chaining and '>' redirection are Bash-tool ergonomics only. PowerShell uses ';' as
	# its statement separator and '>' / '2>&1' as normal redirection, so these two stay
	# scoped to the Bash tool. The git/co-author policy above is NOT scoped -- it binds every shell.
	if ($json.tool_name -eq "Bash") {
		if ($cmd -match ';') {
			@{
				decision = "block"
				reason   = "Do not chain multiple commands with ';'. Run one command at a time."
			} | ConvertTo-Json -Compress
			exit 0
		}

		if ($cmd -match '[>]{1,2}\s*\S+') {
			@{
				decision = "block"
				reason   = "Use tee instead of > or >> for output redirection."
			} | ConvertTo-Json -Compress
			exit 0
		}
	}
	
	# CMake must go THROUGH a preset. A bare 'cmake --build' or bare configure re-runs
	# vcpkg with the shell environment, missing VCPKG_BINARY_SOURCES and the shared
	# installed dir -- so it rebuilds every port from source into the wrong cache. Only
	# enforced when the cwd actually has presets, so non-preset projects are untouched.
	if ($cmd -match '\bcmake(\.exe)?\b' -and $cmd -notmatch '--preset') {
		$isBuild     = $cmd -match '\bcmake(\.exe)?\b[^\n]*--build'
		$isConfigure = $cmd -match '\bcmake(\.exe)?\s+(-S\b|-B\b|-D|-G\b|\.(\s|$)|\.\.|[A-Za-z]:[\\/]|/)'
		$isUtility   = $cmd -match '\bcmake(\.exe)?\s+(-E\b|--version|--help|--list-presets|--build\s+--preset)'
		if (($isBuild -or $isConfigure) -and -not $isUtility) {
			$cwd = "$($json.cwd)"
			$hasPresets = $false
			if ($cwd) {
				foreach ($f in @('CMakePresets.json', 'CMakeUserPresets.json')) {
					if (Test-Path -LiteralPath (Join-Path $cwd $f)) { $hasPresets = $true; break }
				}
			}
			if ($hasPresets) {
				@{
					decision = "block"
					reason   = "This repo uses CMake presets -- run cmake THROUGH the preset so its environment (VCPKG_BINARY_SOURCES, the shared vcpkg installed dir) applies. A bare cmake reconfigures with the shell env, misses the vcpkg binary cache, and rebuilds every port from source. Configure: cmake --preset <name> (e.g. cwdming). Build: cmake --build --preset <name> (or cmake --build <preset-build-dir> only if you are certain no reconfigure will trigger)."
				} | ConvertTo-Json -Compress
				exit 0
			}
		}
	}

	# Allow the specific PR inline-comments endpoint (the block below is too broad for this case)
	if ($cmd -match '^gh\s+api\s+-X\s+GET\s+repos/[^/\s]+/[^/\s]+/pulls/\d+/comments\b') {
		@{
			decision = "approve"
			reason   = "gh api .../pulls/<n>/comments is the correct endpoint for inline review comments."
		} | ConvertTo-Json -Compress
		exit 0
	}
	
	# gh api must ALWAYS start with gh api -X GET immediately after gh api
	if ($cmd -match '^gh\s+api\b' -and $cmd -notmatch '^gh\s+api\s+-X\s+GET\b') {
		@{
			decision = "block"
			reason   = "gh api calls must start with: gh api -X GET"
		} | ConvertTo-Json -Compress
		exit 0
	}
}

if ($json.tool_name -eq "Write" -or $json.tool_name -eq "Edit") {
    $path = ($json.tool_input.file_path -replace '\\', '/')

    # Protect files whose edits trigger expensive vcpkg rebuilds. Ask the user first.
    $protected = ($path -match '/(CMakeUserPresets|CMakePresets|vcpkg)\.json$') -or
                 ($path -match '/triplets/[^/]+\.cmake$') -or
                 ($path -match '/ports/.*/(portfile\.cmake|vcpkg\.json)$')
    if ($protected) {
        @{
            decision = "block"
            reason   = "Do not modify CMake presets, vcpkg.json, triplet files, or overlay ports without asking first. These can trigger expensive vcpkg rebuilds. Ask the user before editing."
        } | ConvertTo-Json -Compress
        exit 0
    }

    # No em-dash (U+2014) in any written file. Rewrite the sentence instead.
    $written = "$($json.tool_input.content)$($json.tool_input.new_string)"
    if ($written.Contains([char]0x2014)) {
        @{
            decision = "block"
            reason   = "Never use the em-dash character (U+2014). Rewrite the sentence: split it, or use a comma, parentheses, or a colon."
        } | ConvertTo-Json -Compress
        exit 0
    }

    # No !important in stylesheets.
    if ($path -match '\.(css|scss|sass|less)$') {
        $content = "$($json.tool_input.content)$($json.tool_input.new_string)"
        if ($content -match '!important') {
            @{
                decision = "block"
                reason   = "Never add !important to CSS rules. Rework the selector specificity instead."
            } | ConvertTo-Json -Compress
            exit 0
        }
    }

    # .env files hold secrets: block writes, EXCEPT default.env, a non-secret template
    # meant to be edited. Approve wins over the built-in .env protection. Checked after
    # the content rules above, so default.env still gets the em-dash and vcpkg guards.
    $leaf = ($path -split '/')[-1]
    if ($leaf -eq 'default.env') {
        @{
            decision = "approve"
            reason   = "default.env is a non-secret template, so writing it is allowed."
        } | ConvertTo-Json -Compress
        exit 0
    }
    if ($leaf -eq '.env' -or $leaf -like '.env.*' -or $leaf -like '*.env') {
        @{
            decision = "block"
            reason   = "Do not write .env files (they hold secrets). Only default.env may be written."
        } | ConvertTo-Json -Compress
        exit 0
    }
}

exit 0