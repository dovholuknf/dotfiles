#!/usr/bin/env bash
# Replay every patch, in order, into a clean copy of the baseline.
#
#   verify.sh <repo> <outdir>
#
# The point is to prove the thing being handed over: that `git apply -p1` works
# from the repo root, one patch at a time, starting from the commit the user is
# sitting on. Then it diffs the result against the last snapshot, which is the
# tree that was actually tested. Byte-identical or the series is wrong.
set -eu

REPO="${1:?usage: verify.sh <repo> <outdir>}"
OUT="${2:?}"
WORK="$OUT/verify"

rm -rf "$WORK"
mkdir -p "$WORK"
cp -r "$OUT/snap/00-base/." "$WORK/"

cd "$WORK"
# A repository, so `git apply` behaves the way it will for the user rather than
# falling back to its no-index mode.
git init --quiet .
git -c user.email=x@y -c user.name=x add -A
git -c user.email=x@y -c user.name=x commit --quiet -m baseline

last=""
for p in "$OUT"/patches/*.patch; do
  name=$(basename "$p")
  if ! git apply --check -p1 "$p" 2>/dev/null; then
    echo "FAILED to apply cleanly: $name"
    git apply -p1 "$p" || true
    exit 1
  fi
  git apply -p1 "$p"
  git -c user.email=x@y -c user.name=x add -A
  git -c user.email=x@y -c user.name=x commit --quiet -m "$name"
  echo "applied $name"
  last="${name%.patch}"
  last="${last#*-}"
done

rm -rf "$WORK/.git"

# The last snapshot is the tree that was tested. Anything here means a patch
# does not reconstruct what was verified.
final="$OUT/snap/$last"
if [ ! -d "$final" ]; then
  echo "no snapshot for the last patch ($last); cannot compare."
  exit 1
fi

if git diff --no-index --quiet "$WORK" "$final"; then
  echo "--- all patches applied, and the result matches the tested tree ---"
  rm -rf "$WORK"
else
  echo "--- MISMATCH: the replay differs from the tested tree ---"
  git diff --no-index --stat "$WORK" "$final" | tail -20
  exit 1
fi
