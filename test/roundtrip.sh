#!/usr/bin/env bash
# Functional round-trip suite for a built josh-proxy binary.
#
#   test/roundtrip.sh <path-to-josh-proxy> [local-cache-dir]
#
# The optional second argument overrides josh's --local cache directory — the
# Windows job passes relative / space-laden / subst-drive forms through here to
# regression-test the josh#2288 path-mangling class (the bug bites on cache
# *reuse*, which is why the warm fetch happens across a proxy restart).
#
# Requires: git, go, curl on PATH. Everything runs against 127.0.0.1.
set -euo pipefail

JOSH_PROXY="$1"
WORK="$(mktemp -d)"
LOCAL_DIR="${2:-$WORK/josh-local}"
GIT_PORT="${GIT_PORT:-42180}"
JOSH_PORT="${JOSH_PORT:-42190}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_BRANCH="main" # the branch the seed repo below creates; -o base= derives from it

GIT_SRV_PID=""
JOSH_PID=""
cleanup() {
  [ -n "$JOSH_PID" ] && kill "$JOSH_PID" 2>/dev/null || true
  [ -n "$GIT_SRV_PID" ] && kill "$GIT_SRV_PID" 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_port() { # host:port must accept within ~10s
  for _ in $(seq 1 100); do
    # curl exit 7 = connection refused; anything else means the port answered
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" && return 0
    [ "$?" -ne 7 ] && return 0
    sleep 0.1
  done
  return 1
}

start_proxy() {
  "$JOSH_PROXY" --local "$LOCAL_DIR" --remote "http://127.0.0.1:$GIT_PORT" \
    "--port=$JOSH_PORT" --no-background >>"$WORK/josh.log" 2>&1 &
  JOSH_PID=$!
  wait_port "$JOSH_PORT" || { cat "$WORK/josh.log" >&2; fail "josh-proxy never became ready"; }
}

stop_proxy() { # must exit within 2s of termination and leave no orphans
  kill "$JOSH_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$JOSH_PID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$JOSH_PID" 2>/dev/null; then fail "josh-proxy did not exit within 2s of termination"; fi
  JOSH_PID=""
  # Name-agnostic orphan check (validate runs a renamed binary): nothing may
  # still be accepting on the proxy port once the process is gone.
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$JOSH_PORT/"; then
    fail "something still listening on the josh port after shutdown (orphan process?)"
  fi
}

echo "== setup: local upstream served over smart HTTP"
mkdir -p "$WORK/srv"
git init -q --bare "$WORK/srv/upstream.git"
git -C "$WORK/srv/upstream.git" config http.receivepack true
git init -q -b "$BASE_BRANCH" "$WORK/seed"
git -C "$WORK/seed" config user.email t@t && git -C "$WORK/seed" config user.name t
echo "hello" > "$WORK/seed/README.md"
git -C "$WORK/seed" add . && git -C "$WORK/seed" commit -qm "c1: readme"
C1="$(git -C "$WORK/seed" rev-parse HEAD)"
mkdir -p "$WORK/seed/src" && echo "lib" > "$WORK/seed/src/lib.txt"
git -C "$WORK/seed" add . && git -C "$WORK/seed" commit -qm "c2: lib"
C2="$(git -C "$WORK/seed" rev-parse HEAD)"
git -C "$WORK/seed" push -q "$WORK/srv/upstream.git" "$BASE_BRANCH"

# Build first, run the binary: `go run` compiles the (uncached) stdlib on a
# fresh runner, which can outlast any readiness budget; a blocking build makes
# the wait below measure only the bind.
GITHTTP="$WORK/githttp$(go env GOEXE)"
go build -o "$GITHTTP" "$SCRIPT_DIR/githttp/main.go" || fail "building githttp helper"
"$GITHTTP" -root "$WORK/srv" -port "$GIT_PORT" &
GIT_SRV_PID=$!
wait_port "$GIT_PORT" || fail "git http server never became ready"

echo "== boot: josh-proxy --local '$LOCAL_DIR'"
start_proxy

FILTERED_URL="http://127.0.0.1:$JOSH_PORT/upstream.git:prefix=lib.git"

echo "== filtered clone (:prefix)"
git clone -q "$FILTERED_URL" "$WORK/clone"
[ -f "$WORK/clone/lib/README.md" ] || fail "prefix mapping missing (lib/README.md)"
[ "$(git -C "$WORK/clone" rev-list --count HEAD)" = "2" ] || fail "filtered history should have 2 commits"

echo "== pinned-SHA fetch (@sha)"
# %3A form: consumers hit both the raw ':' filter separator (the clone above)
# and the URL-encoded one; on Windows the encoded segment is a josh#2288 watch
# point, so cover it here.
git -C "$WORK/clone" fetch -q "http://127.0.0.1:$JOSH_PORT/upstream.git@$C1%3Aprefix=lib.git" HEAD
git -C "$WORK/clone" ls-tree --name-only -r FETCH_HEAD | grep -qx "lib/README.md" \
  || fail "pinned fetch missing lib/README.md"
git -C "$WORK/clone" ls-tree --name-only -r FETCH_HEAD | grep -q "lib/src" \
  && fail "pinned fetch resolved past the pinned commit (lib/src present at c1)"

echo "== reverse push (the round-trip)"
git -C "$WORK/clone" config user.email t@t && git -C "$WORK/clone" config user.name t
echo "change" >> "$WORK/clone/lib/src/lib.txt"
git -C "$WORK/clone" commit -qam "c3: change via filtered view"
# josh refuses to create a ref that doesn't exist on the remote unless the
# push names a base to root it on. A fresh PR branch is the normal case for
# consumers (rig's `stack send`), so exercise exactly that spelling.
git -C "$WORK/clone" push -q -o "base=refs/heads/$BASE_BRANCH" origin HEAD:refs/heads/roundtrip
RT="$(git -C "$WORK/srv/upstream.git" rev-parse refs/heads/roundtrip)" \
  || fail "roundtrip branch missing on upstream"
git -C "$WORK/srv/upstream.git" show "$RT:src/lib.txt" | grep -q "change" \
  || fail "reverse-filtered change not at src/lib.txt (prefix not stripped?)"
[ "$(git -C "$WORK/srv/upstream.git" rev-parse "$RT^")" = "$C2" ] \
  || fail "re-rooted commit's parent is not the upstream tip (broken ancestry)"
git -C "$WORK/srv/upstream.git" log -1 --format=%s "$RT" | grep -q "c3: change" \
  || fail "commit message lost in reverse filtering"

echo "== clean shutdown, then warm-cache reuse across a restart"
# Consumers run one proxy per operation, never a daemon — the --local cache
# must survive a clean stop and serve the next proxy instance. A same-process
# refetch can't catch corruption-on-shutdown; a restart does. This is also
# where the josh#2288 path mangling bites.
stop_proxy
start_proxy
git -C "$WORK/clone" fetch -q origin || fail "warm fetch after proxy restart failed (cache reuse)"

echo "== teardown"
stop_proxy

echo "PASS: round-trip suite (local cache: $LOCAL_DIR)"
