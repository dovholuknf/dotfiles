#!/usr/bin/env bash
# Claude Code statusline, fork-minimized. Exactly one jq, one git, one stat per
# render; everything else is a bash builtin (printf '%()T' for the clock,
# printf -v / $'...' for string building, a here-string into jq instead of cat).
# The earlier version forked cat + jq + two git + date + ~10 printf subshells
# and ran ~1s per render; this trims that to three external processes.

input=$(cat)

# One jq pass pulls every field, tab-separated. Numbers default to -1 so the
# formatter can tell "zero" from "not reported"; strings default to empty.
# Windows backslash paths are valid JSON (escaped), so jq handles the real
# payload; if it ever fails, every field comes back empty and we degrade.
IFS=$'\t' read -r cwd fh_pct fh_reset wk_pct ctx_pct ctx_used ctx_size tpath < <(
  jq -r '
    [ (.workspace.current_dir // .cwd // "")
    , (.rate_limits.five_hour.used_percentage // -1)
    , (.rate_limits.five_hour.resets_at // -1)
    , (.rate_limits.seven_day.used_percentage // -1)
    , (.context_window.used_percentage // -1)
    , (.context_window.total_input_tokens // -1)
    , (.context_window.context_window_size // -1)
    , (.transcript_path // "")
    ] | @tsv' 2>/dev/null <<<"$input")
# @tsv escapes backslashes, doubling them in Windows paths (D:\\git\\...). Undo
# that on the two path-bearing fields so the bar and the stat check see real paths.
cwd=${cwd//\\\\/\\}
tpath=${tpath//\\\\/\\}
[ -z "$cwd" ] && cwd=$(pwd)

# Clock and "now" via the printf builtin, no date fork.
printf -v datetime '%(%a %b %d, %H:%M:%S)T' -1
printf -v now_epoch '%(%s)T' -1

# Branch: one git call. rev-parse --abbrev-ref already fails cleanly outside a
# repo, so the separate --git-dir probe the old version ran was redundant.
git_branch=$(git --no-optional-locks -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)

# --- colors / formatters, all fork-free (set globals via printf -v) ---

# green under 60, yellow to 85, red above. Sets PCOL.
pct_color() {
    local p=${1%%.*}
    if   [ -z "$p" ] || [ "$p" -lt 0 ] 2>/dev/null; then PCOL=90
    elif [ "$p" -ge 85 ]; then PCOL=31
    elif [ "$p" -ge 60 ]; then PCOL=33
    else PCOL=32
    fi
}

# "2h14m" until the given epoch, empty if unset or past. Sets RESET.
until_reset() {
    local at=${1%%.*} d
    RESET=""
    [ -z "$at" ] && return
    [ "$at" -le 0 ] 2>/dev/null && return
    d=$(( at - now_epoch ))
    [ "$d" -le 0 ] && return
    if [ "$d" -ge 3600 ]; then printf -v RESET '%dh%02dm' $((d/3600)) $(((d%3600)/60))
    else printf -v RESET '%dm' $((d/60))
    fi
}

# Append a " | <label><pct>%<suffix>" colored segment to $right (leading
# separator included so callers don't juggle it). No subshell.
seg() {
    local label=$1 pct=${2%%.*} suffix=$3 tmp
    [ -z "$pct" ] && return
    [ "$pct" -lt 0 ] 2>/dev/null && return
    pct_color "$pct"
    printf -v tmp '\033[90m  |\033[0m\033[90m%s\033[0m\033[%sm%s%%\033[0m' "$label" "$PCOL" "$pct"
    right+=$tmp
    if [ -n "$suffix" ]; then
        printf -v tmp '\033[90m%s\033[0m' "$suffix"
        right+=$tmp
    fi
}

# --- left: cwd, branch, clock ---
printf -v left '\033[32m%s\033[0m ' "$cwd"
if [ -n "$git_branch" ]; then
    printf -v tmp '\033[33m(%s)\033[0m ' "$git_branch"
    left+=$tmp
fi
printf -v tmp '\033[90m[%s]\033[0m' "$datetime"
left+=$tmp

# --- right: 5h limit + reset, weekly limit, context, transcript size ---
right=""
until_reset "$fh_reset"
fh_suffix=""
[ -n "$RESET" ] && fh_suffix=" ($RESET)"
seg " 5h " "$fh_pct" "$fh_suffix"
seg " wk " "$wk_pct"

# Context: raw tokens with a zone that gets louder as it fills. 200k is the one
# non-arbitrary threshold (past it the 1M context moves to the premium tier);
# 75%/90% are judgement, 90% leaving ~100k to finish and compact deliberately.
u=${ctx_used%%.*}
z=${ctx_size%%.*}
if [ -n "$u" ] && [ "$u" -ge 0 ] 2>/dev/null && [ -n "$z" ] && [ "$z" -gt 0 ] 2>/dev/null; then
    pct=$(( u * 100 / z ))
    if [ "$pct" -ge 90 ]; then
        printf -v tmp '\033[90m  |\033[0m\033[1;97;41m  LAND THE PLANE  %s/%s  (%s%%)  /compact  \033[0m' "$u" "$z" "$pct"
    elif [ "$pct" -ge 75 ]; then
        printf -v tmp '\033[90m  |\033[0m\033[1;33m ctx %s/%s (%s%%) getting full\033[0m' "$u" "$z" "$pct"
    elif [ "$u" -le 200000 ]; then
        printf -v tmp '\033[90m  |\033[0m\033[90m ctx \033[0m\033[32m%s\033[0m\033[90m/%s\033[0m\033[32m sweet\033[0m' "$u" "$z"
    else
        printf -v tmp '\033[90m  |\033[0m\033[90m ctx \033[0m\033[36m%s\033[0m\033[90m/%s (%s%%)\033[0m' "$u" "$z" "$pct"
    fi
    right+=$tmp
else
    seg " ctx " "$ctx_pct"
fi

# Transcript size: how big this session's .jsonl has grown. Big means more
# compaction and slower resumes. Decimal MB. One stat, skipped if unavailable.
# transcript_path arrives Windows-style (C:\Users\...); coreutils stat/test need
# a git-bash path, so convert a drive-letter path to /c/... before touching disk.
case $tpath in
  [A-Za-z]:\\*|[A-Za-z]:/*) _d=${tpath:0:1}; _r=${tpath:2}; tpath="/${_d,,}${_r//\\//}" ;;
esac
if [ -f "$tpath" ]; then
    bytes=$(stat -c %s "$tpath" 2>/dev/null || echo 0)
    if [ "$bytes" -gt 0 ] 2>/dev/null; then
        mb=$(( bytes / 1000000 ))
        if   [ "$bytes" -ge 1000000 ]; then hs="${mb}M"
        elif [ "$bytes" -ge 1000 ];    then hs="$(( bytes / 1000 ))K"
        else hs="${bytes}B"
        fi
        if   [ "$mb" -ge 50 ]; then tc=31
        elif [ "$mb" -ge 20 ]; then tc=33
        else tc=90
        fi
        printf -v tmp '\033[90m  |\033[0m\033[%sm tx %s\033[0m' "$tc" "$hs"
        right+=$tmp
    fi
fi

printf '%s%s' "$left" "$right"
