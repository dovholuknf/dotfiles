# Sourced by githooks/pre-push and githooks/agent/commit-msg. No LLM may become a contributor: GitHub lists the author,
# the committer and every co-author trailer of each commit, matched by name and email. A commit naming claude or
# anthropic in any of them puts Claude on the repo's contributor list, and a rewrite does not take it off again
# (GitHub keeps the unreachable commit). So it is refused before it exists, and again before it leaves.

# An identity line is 'Name <email>'. Refused: the name 'claude', or an email naming claude or anthropic.
ATTR_IDENT_RE='^claude <|<[^>]*(claude|anthropic)[^>]*>'
# A message line that credits an LLM: a co-author trailer naming one, its noreply address, or a "Generated with" line.
ATTR_MSG_RE='^co-authored-by:.*(claude|anthropic)|noreply@anthropic[.]com|generated with .*claude'

# attr_scan_commits <rev-list args...>: prints one line per offending commit and returns 1 if any.
attr_scan_commits() {
    hits=$(git log --format='%h%x09%an <%ae>%x09%cn <%ce>' "$@" 2>/dev/null | while IFS='	' read -r h a c; do
        for who in "$a" "$c"; do
            if printf '%s\n' "$who" | grep -qiE "$ATTR_IDENT_RE"; then printf '  %s  identity: %s\n' "$h" "$who"; fi
        done
    done)
    msgs=$(git log --format='@@%h%n%B' "$@" 2>/dev/null | awk -v re="$ATTR_MSG_RE" '
        /^@@/ { h = substr($0, 3); next }
        tolower($0) ~ re { printf "  %s  message:  %s\n", h, $0 }')
    [ -z "$hits$msgs" ] && return 0
    [ -n "$hits" ] && printf '%s\n' "$hits"
    [ -n "$msgs" ] && printf '%s\n' "$msgs"
    return 1
}

# attr_run_repo_hook <name> [args...]: runs the repo's own hook of that name, if it has one. core.hooksPath replaces
# .git/hooks, so without this git-lfs and per-repo hooks would stop running. A repo-local core.hooksPath (husky) is
# honoured too. Reads the hook's stdin from ours.
attr_run_repo_hook() {
    name=$1
    shift
    dir=$(git config --local --get core.hooksPath 2>/dev/null)
    if [ -n "$dir" ]; then
        case "$dir" in /*|[A-Za-z]:*) ;; *) dir="$(git rev-parse --show-toplevel)/$dir" ;; esac
    else
        dir="$(git rev-parse --git-common-dir)/hooks"
    fi
    hook="$dir/$name"
    if [ -f "$hook" ] && [ "$hook" != "$0" ]; then
        "$hook" "$@"
        return $?
    fi
    return 0
}
