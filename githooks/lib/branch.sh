# Sourced by the agent hooks (githooks/agent/*). The agent account may edit files in clint's worktrees, but it may
# commit only on its own claude/* branches. The PreToolUse gate checks this too, but it reads command text, so it misses
# git run from a script, '-C', '--work-tree', GIT_DIR, or a 'cd X; git commit' in one call. Git runs this hook for every
# commit however it was started. The gate blocks the two ways around it: --no-verify and a core.hooksPath override.

# agent_require_claude_branch <hook-name>: refuses a commit or merge commit unless HEAD is a claude/* branch. A detached
# HEAD passes (its commits land on no branch), except mid-rebase, where the branch being rebased is the one that counts.
agent_require_claude_branch() {
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        for d in rebase-merge rebase-apply; do
            hn=$(git rev-parse --git-path "$d/head-name" 2>/dev/null)
            if [ -n "$hn" ] && [ -f "$hn" ]; then
                branch=$(sed 's|^refs/heads/||' "$hn")
                break
            fi
        done
    fi
    [ -z "$branch" ] && return 0
    case "$branch" in claude/*) return 0 ;; esac
    printf '\n  BLOCKED (%s): the agent may commit only on a claude/* branch. HEAD is %s.\n' "$1" "$branch" 1>&2
    printf '  Leave the change in the working tree for clint to commit.\n\n' 1>&2
    return 1
}
