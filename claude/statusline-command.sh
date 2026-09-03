#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON. Windows paths contain backslashes that are invalid
# JSON escape sequences (e.g. \g, \d), so jq often fails on them. Fall back to
# pwd, which is the actual cwd of the Claude Code process anyway.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd' 2>/dev/null)
if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
    cwd=$(pwd)
fi

# Get date and time
datetime=$(date "+%a %b %d, %H:%M:%S")

# Get git branch (skip optional locks for performance)
git_branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

# One jq pass for every usage number, tab separated. Missing fields come back as
# -1 so the formatter can tell "zero" apart from "this version does not report it".
usage=$(echo "$input" | jq -r '
  [ (.rate_limits.five_hour.used_percentage  // -1)
  , (.rate_limits.five_hour.resets_at        // -1)
  , (.rate_limits.seven_day.used_percentage  // -1)
  , (.context_window.used_percentage         // -1)
  , (.context_window.total_input_tokens      // -1)
  , (.context_window.context_window_size     // -1)
  ] | @tsv' 2>/dev/null)
IFS=$'\t' read -r fh_pct fh_reset wk_pct ctx_pct ctx_used ctx_size <<< "$usage"

# green under 60, yellow to 85, red above
pct_color() {
    local p=${1%%.*}
    if   [ -z "$p" ] || [ "$p" -lt 0 ] 2>/dev/null; then printf '90'
    elif [ "$p" -ge 85 ]; then printf '31'
    elif [ "$p" -ge 60 ]; then printf '33'
    else printf '32'
    fi
}

# "2h14m" until the given epoch, empty if it is unset or already past
until_reset() {
    local at=${1%%.*}
    [ -z "$at" ] && return
    [ "$at" -le 0 ] 2>/dev/null && return
    local d=$(( at - $(date +%s) ))
    [ "$d" -le 0 ] && return
    if [ "$d" -ge 3600 ]; then printf '%dh%02dm' $((d/3600)) $(((d%3600)/60))
    else printf '%dm' $((d/60))
    fi
}

seg() {  # seg <label> <pct> [suffix]
    local label=$1 pct=${2%%.*} suffix=$3
    [ -z "$pct" ] && return
    [ "$pct" -lt 0 ] 2>/dev/null && return
    printf "\033[90m%s\033[0m\033[%sm%s%%\033[0m" "$label" "$(pct_color "$pct")" "$pct"
    [ -n "$suffix" ] && printf "\033[90m%s\033[0m" "$suffix"
}

left=""
left="${left}$(printf "\033[32m%s\033[0m" "$cwd") "
if [ -n "$git_branch" ]; then
    left="${left}$(printf "\033[33m(%s)\033[0m" "$git_branch") "
fi
left="${left}$(printf "\033[90m[%s]\033[0m" "$datetime")"

# usage tail: 5h limit with reset countdown, weekly limit, context, session cost
right=""
fh_left=$(until_reset "$fh_reset")
s=$(seg " 5h " "$fh_pct" "${fh_left:+ (${fh_left})}")
[ -n "$s" ] && right="${right}$(printf "\033[90m  |\033[0m")${s}"
s=$(seg " wk " "$wk_pct")
[ -n "$s" ] && right="${right}$(printf "\033[90m  |\033[0m")${s}"
# Context, as raw tokens with a zone that gets louder as it fills.
#
# 200k is the one threshold that is not arbitrary: past it the 1M context moves to
# the premium long-context tier, so staying under it is the actual sweet spot. The
# 75% and 90% marks above that are judgement, chosen so 90% still leaves roughly
# 100k of room to finish a thought and compact deliberately rather than be cut off.
u=${ctx_used%%.*}
z=${ctx_size%%.*}
if [ -n "$u" ] && [ "$u" -ge 0 ] 2>/dev/null && [ -n "$z" ] && [ "$z" -gt 0 ] 2>/dev/null; then
    pct=$(( u * 100 / z ))
    if [ "$pct" -ge 90 ]; then
        # white on red, bold, with the instruction spelled out
        right="${right}$(printf "\033[90m  |\033[0m\033[1;97;41m  LAND THE PLANE  %s/%s  (%s%%)  /compact  \033[0m" "$u" "$z" "$pct")"
    elif [ "$pct" -ge 75 ]; then
        right="${right}$(printf "\033[90m  |\033[0m\033[1;33m ctx %s/%s (%s%%) getting full\033[0m" "$u" "$z" "$pct")"
    elif [ "$u" -le 200000 ]; then
        right="${right}$(printf "\033[90m  |\033[0m\033[90m ctx \033[0m\033[32m%s\033[0m\033[90m/%s\033[0m\033[32m sweet\033[0m" "$u" "$z")"
    else
        right="${right}$(printf "\033[90m  |\033[0m\033[90m ctx \033[0m\033[36m%s\033[0m\033[90m/%s (%s%%)\033[0m" "$u" "$z" "$pct")"
    fi
else
    s=$(seg " ctx " "$ctx_pct")
    [ -n "$s" ] && right="${right}$(printf "\033[90m  |\033[0m")${s}"
fi
printf "%s%s" "$left" "$right"
