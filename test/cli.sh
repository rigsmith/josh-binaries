#!/usr/bin/env bash
# Functional suite for the josh CLI binaries (josh, josh-filter) — the
# proxy-less side of josh: filtering, cloning, pulling and pushing with the
# history math done in-process against ordinary git transports.
#
#   test/cli.sh <dir-containing-josh-and-josh-filter>
#
# The `josh clone` step deliberately uses a *relative* output directory: that
# is the reported trigger for josh#2288's path mangling on Windows.
#
# Requires: git, go, curl on PATH. Everything runs against 127.0.0.1.
set -euo pipefail

BIN_DIR="$(cd "$1" && pwd)"
EXE=""
[ -f "$BIN_DIR/josh.exe" ] && EXE=".exe"
JOSH="$BIN_DIR/josh$EXE"
JOSH_FILTER="$BIN_DIR/josh-filter$EXE"
[ -f "$JOSH" ] || { echo "FAIL: $JOSH not found" >&2; exit 1; }
[ -f "$JOSH_FILTER" ] || { echo "FAIL: $JOSH_FILTER not found" >&2; exit 1; }

WORK="$(mktemp -d)"
GIT_PORT="${GIT_PORT:-42280}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_BRANCH="main"

GIT_SRV_PID=""
cleanup() { [ -n "$GIT_SRV_PID" ] && kill "$GIT_SRV_PID" 2>/dev/null || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_port() {
  for _ in $(seq 1 100); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" && return 0
    [ "$?" -ne 7 ] && return 0
    sleep 0.1
  done
  return 1
}

echo "== setup: local upstream served over smart HTTP"
mkdir -p "$WORK/srv"
git init -q --bare -b "$BASE_BRANCH" "$WORK/srv/upstream.git"
git -C "$WORK/srv/upstream.git" config http.receivepack true
git init -q -b "$BASE_BRANCH" "$WORK/seed"
git -C "$WORK/seed" config user.email t@t && git -C "$WORK/seed" config user.name t
echo "hello" > "$WORK/seed/README.md"
git -C "$WORK/seed" add . && git -C "$WORK/seed" commit -qm "c1: readme"
mkdir -p "$WORK/seed/src" && echo "lib" > "$WORK/seed/src/lib.txt"
git -C "$WORK/seed" add . && git -C "$WORK/seed" commit -qm "c2: lib"
C2="$(git -C "$WORK/seed" rev-parse HEAD)"
git -C "$WORK/seed" push -q "$WORK/srv/upstream.git" "$BASE_BRANCH"

GITHTTP="$WORK/githttp$(go env GOEXE)"
go build -o "$GITHTTP" "$SCRIPT_DIR/githttp/main.go" || fail "building githttp helper"
"$GITHTTP" -root "$WORK/srv" -port "$GIT_PORT" &
GIT_SRV_PID=$!
wait_port "$GIT_PORT" || fail "git http server never became ready"
UPSTREAM_URL="http://127.0.0.1:$GIT_PORT/upstream.git"

echo "== josh-filter: in-process history filtering"
git clone -q "$UPSTREAM_URL" "$WORK/plain"
(cd "$WORK/plain" && "$JOSH_FILTER" ":prefix=lib" "$BASE_BRANCH") || fail "josh-filter run"
git -C "$WORK/plain" ls-tree --name-only -r FILTERED_HEAD | grep -qx "lib/README.md" \
  || fail "josh-filter: prefix mapping missing in FILTERED_HEAD"
[ "$(git -C "$WORK/plain" rev-list --count FILTERED_HEAD)" = "2" ] \
  || fail "josh-filter: filtered history should have 2 commits"

echo "== josh clone (relative out dir — the josh#2288 shape)"
mkdir -p "$WORK/cli" && cd "$WORK/cli"
"$JOSH" clone "$UPSTREAM_URL" ":prefix=lib" ./cli-clone || fail "josh clone"
[ -f "$WORK/cli/cli-clone/lib/README.md" ] || fail "josh clone: prefix mapping missing"
[ "$(git -C "$WORK/cli/cli-clone" rev-list --count HEAD)" = "2" ] \
  || fail "josh clone: filtered history should have 2 commits"

# `pull` moved under `changes` after r26.07.19; support both spellings so the
# suite can test a pinned release and current master with one script.
if "$JOSH" changes pull --help >/dev/null 2>&1; then
  PULL=(changes pull)
else
  PULL=(pull)
fi

echo "== josh ${PULL[*]} after upstream advances"
echo "more" >> "$WORK/seed/src/lib.txt"
git -C "$WORK/seed" commit -qam "c3: more lib"
C3="$(git -C "$WORK/seed" rev-parse HEAD)"
git -C "$WORK/seed" push -q "$WORK/srv/upstream.git" "$BASE_BRANCH"
(cd "$WORK/cli/cli-clone" && "$JOSH" "${PULL[@]}") || fail "josh ${PULL[*]}"
grep -q "more" "$WORK/cli/cli-clone/lib/src/lib.txt" \
  || fail "josh ${PULL[*]}: upstream change did not arrive through the filter"

echo "== josh push (reverse filtering, in-process)"
cd "$WORK/cli/cli-clone"
git config user.email t@t && git config user.name t
echo "cli-change" >> lib/src/lib.txt
git commit -qam "c4: change via cli clone"
# --base roots the reverse-filtered commit on real upstream history. Without
# it the CLI silently pushes a PARENTLESS commit (correct tree, no ancestry) —
# where the proxy path refuses outright. Assert exact parentage so an orphan
# can never pass.
"$JOSH" push origin "HEAD:refs/heads/cli-roundtrip" --base "$BASE_BRANCH" || fail "josh push"
RT="$(git -C "$WORK/srv/upstream.git" rev-parse refs/heads/cli-roundtrip)" \
  || fail "josh push: branch missing on upstream"
git -C "$WORK/srv/upstream.git" show "$RT:src/lib.txt" | grep -q "cli-change" \
  || fail "josh push: change not reverse-filtered to src/lib.txt"
[ "$(git -C "$WORK/srv/upstream.git" rev-parse "$RT^")" = "$C3" ] \
  || fail "josh push: pushed commit's parent is not the upstream tip (orphan or wrong base)"

echo "PASS: cli suite"
