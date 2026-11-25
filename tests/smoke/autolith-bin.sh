#!/usr/bin/env bash
# Smoke test for autolith-bin.  Autolith's first full `--version'/`--help'
# builds recovery and active images under XDG_DATA_HOME, which takes minutes
# and is exactly the wrong thing to do in a CI smoke test.  The release
# launcher exposes a fast probe instead; use it, then verify the bundled SBCL
# runtime starts.  Set FULL_SMOKE=1 to opt into the slow full command line.
set -euo pipefail
out="${1:?usage: $0 STORE-PATH}"

fail() { echo "autolith-bin smoke: $*" >&2; exit 1; }

bin=""
for candidate in autolith autolith-bin; do
  if [ -x "$out/bin/$candidate" ]; then bin="$out/bin/$candidate"; break; fi
done
[ -n "$bin" ] || fail "missing $out/bin/autolith"

sbcl="$out/libexec/autolith/runtime/bin/sbcl"
[ -x "$sbcl" ] || fail "missing bundled SBCL: $sbcl"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/cache" "$tmp/state"
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_DATA_HOME="$tmp/data"
export XDG_CACHE_HOME="$tmp/cache"
export XDG_STATE_HOME="$tmp/state"
export NO_COLOR=1
export TERM=dumb
export CI=1

probe=$(timeout 30 "$bin" --autolith-release-probe 2>&1) ||
  fail "--autolith-release-probe failed: $probe"
grep -q 'version=' <<<"$probe" ||
  fail "release probe printed no version=: $probe"
echo "autolith release probe: $(tr '\n' ' ' <<<"$probe" | cut -c1-160)"

sbcl_version=$(timeout 30 "$sbcl" --version 2>&1) ||
  fail "bundled SBCL --version failed: $sbcl_version"
grep -qi 'SBCL' <<<"$sbcl_version" ||
  fail "bundled SBCL printed no SBCL banner: $sbcl_version"
echo "bundled SBCL: $(tr '\n' ' ' <<<"$sbcl_version" | cut -c1-120)"

if [ "${FULL_SMOKE:-0}" = 1 ]; then
  echo "==> FULL_SMOKE=1: running the slow full --version (may build images)"
  slow=$(timeout 300 "$bin" --version 2>&1) ||
    fail "full --version failed: $slow"
  grep -q '[0-9]' <<<"$slow" ||
    fail "full --version printed no version: $slow"
  echo "autolith full --version: $(tr '\n' ' ' <<<"$slow" | cut -c1-120)"
fi

echo "autolith-bin smoke test passed"
