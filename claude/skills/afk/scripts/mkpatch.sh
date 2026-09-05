#!/usr/bin/env bash
# Turn the difference between two snapshots into a patch that applies with
# `git apply -p1` from the repo root.
#
#   mkpatch.sh <outdir> <prev-label> <next-label> <number> <subject>
#
# `git diff --no-index` writes the absolute paths it was handed into the
# header. They get rewritten back to the a/ and b/ prefixes a patch is supposed
# to carry, so the result reads like an ordinary commit diff.
set -eu

OUT="${1:?usage: mkpatch.sh <outdir> <prev> <next> <number> <subject>}"
PREV="${2:?}"
NEXT="${3:?}"
NUM="${4:?}"
SUBJECT="${5:?}"

DEST="$OUT/patches/$NUM-$NEXT.patch"
mkdir -p "$OUT/patches"

# git prints Windows-style absolute paths even when handed POSIX ones, so both
# spellings are stripped.
win() { printf '%s' "$1" | sed -e 's|^/\([a-z]\)/|\U\1:/|'; }
WIN_PREV="$(win "$OUT/snap/$PREV")/"
WIN_NEXT="$(win "$OUT/snap/$NEXT")/"

# --no-index always exits 1 when there is a difference, which is the normal
# case here, so its status is not an error.
git diff --no-index --no-color "$OUT/snap/$PREV" "$OUT/snap/$NEXT" > /tmp/afk-raw.diff || true

{
  echo "Subject: [PATCH $NUM] $SUBJECT"
  echo
  sed -e "s#a/$WIN_PREV#a/#g" \
      -e "s#b/$WIN_NEXT#b/#g" \
      -e "s#a/$WIN_NEXT#a/#g" \
      -e "s#b/$WIN_PREV#b/#g" \
      -e "s#--- $WIN_PREV#--- a/#g" \
      -e "s#+++ $WIN_NEXT#+++ b/#g" \
      /tmp/afk-raw.diff
} > "$DEST"

rm -f /tmp/afk-raw.diff
echo "$DEST"
grep -c '^diff --git' "$DEST" || true
