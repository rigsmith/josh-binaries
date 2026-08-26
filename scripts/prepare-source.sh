#!/usr/bin/env bash
# Clone josh at a tag and apply the Windows port patch when it is not already
# upstream.
#
#   scripts/prepare-source.sh <tag> <dest> [patch-repo] [patch-ref]
#
# Prints one word on stdout:
#   patched  the port applied on top of the tag
#   clean    the tag already contains it (the port landed upstream), so nothing
#            is applied and the build is of unmodified upstream source
#   unpatched  ALLOW_UNPATCHED was set and the port did not apply: the tree is
#            unmodified upstream and will not build on Windows
# Exits 3 when the patch conflicts — that needs a human, so it must not be
# mistaken for "josh is broken on Windows".
set -euo pipefail

TAG="$1"
DEST="$2"
PATCH_REPO="${3:-https://github.com/rigsmith/josh}"
PATCH_REF="${4:-windows-master}"
UPSTREAM="${UPSTREAM_REPO:-https://github.com/josh-project/josh}"

git clone -q "$UPSTREAM" "$DEST"
cd "$DEST"
git checkout -q "$TAG"
# Pin where we started: when TAG names a branch the checkout is not detached,
# so the ref moves with the cherry-pick and cannot be compared against.
START="$(git rev-parse HEAD)"

# Identity is required for cherry-pick; these commits never leave the runner.
git config user.email "ci@rigsmith.dev"
git config user.name "josh-binaries CI"

git remote add winport "$PATCH_REPO"
git fetch -q winport "$PATCH_REF"

# Apply everything the port branch adds, not just its tip: a branch may carry
# several commits, and picking only the last one silently applies a fraction of
# the port. The range is what the branch has that upstream does not.
base="$(git merge-base "$START" FETCH_HEAD)"

if git cherry-pick --allow-empty --keep-redundant-commits "$base..FETCH_HEAD" >/dev/null 2>&1; then
  # Comparing against the tag rather than the previous commit: with a range,
  # "changed nothing" is a property of the result, not of the last pick.
  if git diff --quiet "$START" HEAD; then
    echo clean
  else
    echo patched
  fi
else
  git cherry-pick --abort >/dev/null 2>&1 || true
  # The port is written against master, so it only applies to tags cut after
  # its base. An older tag is not an error: unix binaries still build from it,
  # and the caller decides whether a Windows-less release is acceptable.
  if [ -n "${ALLOW_UNPATCHED:-}" ]; then
    echo unpatched
  else
    echo "windows port does not apply cleanly to $TAG" >&2
    exit 3
  fi
fi
