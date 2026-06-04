$rawInput = [Console]::In.ReadToEnd()
$json = $rawInput | ConvertFrom-Json

if ($json.tool_name -eq "Bash") {
    $cmd = $json.tool_input.command
	
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

exit 0