$rawInput = [Console]::In.ReadToEnd()
$json = $rawInput | ConvertFrom-Json

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
}

exit 0