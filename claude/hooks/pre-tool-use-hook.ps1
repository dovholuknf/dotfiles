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

if ($json.tool_name -eq "Bash") {
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

if ($json.tool_name -eq "Bash") {
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

    # Never mutate the user's git repo. Read-only git (status, log, diff, show, remote, worktree list) is fine.
    if ($cmd -match '\bgit\s+(-\S+\s+)*(add|commit|push|pull|fetch|branch|checkout|rebase|reset|restore|clean)\b') {
        @{
            decision = "block"
            reason   = "Do not mutate the git repo. Hand the command to the user to run instead."
        } | ConvertTo-Json -Compress
        exit 0
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

	# Docker: forbid inline env-var prefixes; env must be passed via flags
	if ($cmd -match '^\s*([A-Za-z_]\w*=\S+\s+)+docker\b') {
		@{
			decision = "block"
			reason   = "Do not prefix inline env vars before docker (e.g. 'FOO=bar docker ...'). Pass env explicitly: 'docker run -e VAR=val', a compose block, or '--env-file'."
		} | ConvertTo-Json -Compress
		exit 0
	}
	
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