#!/usr/bin/env bash
# Claude Code statusline, fork-minimized. One jq, one git, one stat per render, plus tail + jq for the
# prompt segment only when the transcript grew. Everything else is a bash builtin (printf '%()T' for the clock,
# printf -v / $'...' for string building, a here-string into jq instead of cat).
# The earlier version forked cat + jq + two git + date + ~10 printf subshells
# and ran ~1s per render; this trims that to three external processes.

input=$(cat)

# One jq pass pulls every field, tab-separated. Numbers default to -1 so the
# formatter can tell "zero" from "not reported"; strings default to empty.
# Windows backslash paths are valid JSON (escaped), so jq handles the real
# payload; if it ever fails, every field comes back empty and we degrade.
# The same pass emits a second line: the compact usage-log record (see log_usage).
{
  IFS=$'\t' read -r cwd fh_pct fh_reset wk_pct ctx_pct ctx_used ctx_size tpath sid
  read -r logline
} < <(
  jq -r '
    ( [ (.workspace.current_dir // .cwd // "")
      , (.rate_limits.five_hour.used_percentage // -1)
      , (.rate_limits.five_hour.resets_at // -1)
      , (.rate_limits.seven_day.used_percentage // -1)
      , (.context_window.used_percentage // -1)
      , (.context_window.total_input_tokens // -1)
      , (.context_window.context_window_size // -1)
      , (.transcript_path // "")
      , (.session_id // "")
      ] | @tsv ),
    ( { ts: (now | floor), time: (now | todate)
      , session_id, session_name, model_id: .model.id, model_name: .model.display_name
      , effort: .effort.level, fast_mode, version
      , cwd: (.workspace.current_dir // .cwd)
      , five_hour_pct: .rate_limits.five_hour.used_percentage
      , five_hour_resets_at: .rate_limits.five_hour.resets_at
      , seven_day_pct: .rate_limits.seven_day.used_percentage
      , seven_day_resets_at: .rate_limits.seven_day.resets_at
      , ctx_used: .context_window.total_input_tokens
      , ctx_out: .context_window.total_output_tokens
      , ctx_size: .context_window.context_window_size
      , ctx_pct: .context_window.used_percentage
      , current_usage: .context_window.current_usage
      , cost, prompt_cache
      , transcript_path
      } | tojson )' 2>/dev/null <<<"$input")
# @tsv escapes backslashes, doubling them in Windows paths (D:\\git\\...). Undo
# that on the two path-bearing fields so the bar and the stat check see real paths.
cwd=${cwd//\\\\/\\}
tpath=${tpath//\\\\/\\}
[ -z "$cwd" ] && cwd=$(pwd)

# Clock and "now" via the printf builtin, no date fork.
printf -v datetime '%(%a %b %d, %H:%M:%S)T' -1
printf -v now_epoch '%(%s)T' -1

# Usage log for claude/usage/: append the jq record to ~/.claude/usage-log.jsonl when
# this session's 5h or 7d percent changes, else at most once a minute. Per-session
# state ("fh wk epoch") lives in one small file. Builtins only, bar a one-time mkdir.
# Best effort: every error is swallowed so the status line never breaks or slows.
log_usage() {
    local dir=$HOME/.claude/usage-log.state key=${sid//[^A-Za-z0-9-]/} lfh lwk lts
    [ -n "$logline" ] && [ -n "$key" ] || return 0
    [ -d "$dir" ] || mkdir -p "$dir" || return 0
    [ -f "$dir/$key" ] && read -r lfh lwk lts < "$dir/$key"
    [[ $lts =~ ^[0-9]+$ ]] || lts=0
    if [ "$fh_pct" = "$lfh" ] && [ "$wk_pct" = "$lwk" ] && [ $(( now_epoch - ${lts:-0} )) -lt 60 ]; then
        return 0
    fi
    printf '%s\n' "$logline" >> "$HOME/.claude/usage-log.jsonl" || return 0
    printf '%s %s %s\n' "$fh_pct" "$wk_pct" "$now_epoch" > "$dir/$key"
}
log_usage 2>/dev/null

# The context limit is autoCompactWindow, read from the settings files Claude Code reads it from,
# lowest precedence first. Re-read at most once a minute: the value and the epoch it was read at
# are cached per session ("limit epoch"), so most renders cost one builtin read. -1 means no file
# sets it. A missing file slurps /dev/null, an empty array, so one absent file never fails the rest.
ctx_limit_of() {
    local dir=$HOME/.claude/statusline-ctx.state key=${sid//[^A-Za-z0-9-]/} lim ts f files=()
    [ -n "$key" ] || key=nosession
    [ -f "$dir/$key" ] && read -r lim ts < "$dir/$key"
    if [[ $lim =~ ^-?[0-9]+$ ]] && [[ $ts =~ ^[0-9]+$ ]] && [ $(( now_epoch - ts )) -lt 60 ]; then
        CTX_LIMIT=$lim
        return 0
    fi
    for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
             "$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json"; do
        [ -f "$f" ] && files+=("$f") || files+=(/dev/null)
    done
    lim=$(jq -n --slurpfile a "${files[0]}" --slurpfile b "${files[1]}" --slurpfile c "${files[2]}" \
        '[$a[0], $b[0], $c[0]] | map(.autoCompactWindow? // empty) | last // -1')
    [[ $lim =~ ^-?[0-9]+$ ]] || lim=-1
    CTX_LIMIT=$lim
    [ -d "$dir" ] || mkdir -p "$dir" || return 0
    printf '%s %s\n' "$lim" "$now_epoch" > "$dir/$key"
}
CTX_LIMIT=-1
ctx_limit_of 2>/dev/null

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

# Context: raw tokens over the limit the session is cleared at, with a zone that gets louder as
# it fills: under 75% sweet, 75-95% getting full, over 95% LAND THE PLANE. The limit is
# autoCompactWindow (ctx_limit_of above). The model window only when no file sets it: on a 1M
# model that read 18% while the session was nearly due to compact.
u=${ctx_used%%.*}
z=$CTX_LIMIT
[ "$z" -gt 0 ] 2>/dev/null || z=${ctx_size%%.*}
if [ -n "$u" ] && [ "$u" -ge 0 ] 2>/dev/null && [ "$z" -gt 0 ] 2>/dev/null; then
    pct=$(( u * 100 / z ))
    if [ "$pct" -gt 95 ]; then
        printf -v tmp '\033[90m  |\033[0m\033[1;97;41m  LAND THE PLANE  %s/%s  (%s%%)  /compact  \033[0m' "$u" "$z" "$pct"
    elif [ "$pct" -ge 75 ]; then
        printf -v tmp '\033[90m  |\033[0m\033[1;33m ctx %s/%s (%s%%) getting full\033[0m' "$u" "$z" "$pct"
    else
        printf -v tmp '\033[90m  |\033[0m\033[90m ctx \033[0m\033[32m%s\033[0m\033[90m/%s\033[0m\033[32m sweet\033[0m' "$u" "$z"
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

# "1234567" -> "1.2M", "12345" -> "12k". Sets K.
fmtk() {
    local n=${1:-0}
    if   [ "$n" -ge 1000000 ]; then printf -v K '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
    elif [ "$n" -ge 1000 ];    then K="$((n/1000))k"
    else K=$n
    fi
}

# Tokens since the last prompt: context re-read, cache written, output. It grows while the turn runs and
# resets on the next prompt. Counted incrementally: "<key>.turn" holds the byte offset already read plus the
# running totals, so a render with no new transcript lines forks nothing, and a busy one reads only the new
# lines (tail + jq). Streamed replies repeat one message id across entries, so the open id is kept apart and
# merged by max. A first look at a big transcript starts 4 MB from the end.
turn_tokens() {
    local dir=$HOME/.claude/usage-log.state key=${sid//[^A-Za-z0-9-]/} st n res
    local off=0 r=0 w=0 o=0 cid=- cr=0 cw=0 co=0
    [ -n "$key" ] && [ "${bytes:-0}" -gt 0 ] 2>/dev/null || return 0
    [ -d "$dir" ] || mkdir -p "$dir" || return 0
    st=$dir/$key.turn
    [ -f "$st" ] && read -r off r w o cid cr cw co < "$st"
    [[ $off =~ ^[0-9]+$ ]] && [ "$off" -le "$bytes" ] || { off=0 r=0 w=0 o=0 cid=- cr=0 cw=0 co=0; }
    if [ "$bytes" -gt "$off" ]; then
        [ "$off" -eq 0 ] && [ "$bytes" -gt 4000000 ] && off=$(( bytes - 4000000 ))
        res=$(tail -c +$(( off + 1 )) "$tpath" | jq -Rrs --argjson st "[$r,$w,$o,\"$cid\",$cr,$cw,$co]" '
            def prompt: .type == "user" and (.isMeta | not) and (.isSidechain | not) and
              ( ((.message.content | type) == "string"
                  and (.message.content | test("^\\s*<(local-command|bash-)") | not))
                or ((.message.content | type) == "array" and any(.message.content[]; .type == "text")
                  and all(.message.content[]; .type != "tool_result")) );
            . as $s | split("\n") as $l
            | reduce ($l[:-1][] | fromjson?) as $e ($st;
                if ($e | prompt) then [0, 0, 0, "-", 0, 0, 0]
                elif $e.type == "assistant" and $e.message.usage != null and ($e.isSidechain | not) then
                  $e.message.usage as $u
                  | [(($u.cache_read_input_tokens // 0) + ($u.input_tokens // 0)),
                     ($u.cache_creation_input_tokens // 0), ($u.output_tokens // 0)] as $c
                  | if $e.message.id == .[3] then
                      .[4] = ([.[4], $c[0]] | max) | .[5] = ([.[5], $c[1]] | max) | .[6] = ([.[6], $c[2]] | max)
                    else [.[0] + .[4], .[1] + .[5], .[2] + .[6], ($e.message.id // "-"), $c[0], $c[1], $c[2]] end
                else . end)
            | "\(($s | utf8bytelength) - ($l[-1] | utf8bytelength)) \(map(tostring) | join(" "))"' 2>/dev/null)
        read -r n r w o cid cr cw co <<<"$res"
        [[ $n =~ ^[0-9]+$ ]] || return 0
        off=$(( off + n ))
        printf '%s %s %s %s %s %s %s %s\n' "$off" "$r" "$w" "$o" "$cid" "$cr" "$cw" "$co" > "$st"
    fi
    local kr kw ko
    fmtk $(( r + cr )); kr=$K
    fmtk $(( w + cw )); kw=$K
    fmtk $(( o + co )); ko=$K
    printf -v tmp '\033[90m  | prompt\033[0m %s %s %s' "$kr" "$kw" "$ko"
    right+=$tmp
}
turn_tokens 2>/dev/null

printf '%s%s' "$left" "$right"
