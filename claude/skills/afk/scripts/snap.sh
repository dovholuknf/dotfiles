#!/usr/bin/env bash
# Snapshot a repo's working tree, so the next patch can be diffed against it.
#
#   snap.sh <repo> <outdir> <label>
#
# Only files git already knows about, plus untracked files that are not
# ignored. That keeps .git, build output and any database out of the snapshot,
# so a snapshot is exactly the source a patch would carry.
set -eu

REPO="${1:?usage: snap.sh <repo> <outdir> <label>}"
OUT="${2:?}"
LABEL="${3:?}"
DEST="$OUT/snap/$LABEL"

cd "$REPO"
rm -rf "$DEST"
mkdir -p "$DEST"

{
  git ls-files
  git ls-files --others --exclude-standard
} | sort -u | tr '\n' '\0' | tar --null -c -T - | tar -x -C "$DEST"

echo "snapshot $LABEL: $(git ls-files | wc -l) tracked files captured"
