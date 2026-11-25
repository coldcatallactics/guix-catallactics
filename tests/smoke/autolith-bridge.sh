#!/usr/bin/env bash
# Smoke test for autolith-bridge (the autolith-remote bridge).  The package may
# be absent while it is blocked upstream; build-all.sh only invokes this when a
# package of that name was actually built.  A bridge has no session to start in
# CI, so exercise its command-line surface: `--help' first, `--version' as a
# fallback.  No network or credentials are required for either.
set -euo pipefail
out="${1:?usage: $0 STORE-PATH}"

fail() { echo "autolith-bridge smoke: $*" >&2; exit 1; }

bin=""
for candidate in autolith-bridge autolith-remote bridge; do
  if [ -x "$out/bin/$candidate" ]; then bin="$out/bin/$candidate"; break; fi
done
[ -n "$bin" ] || fail "no bridge executable under $out/bin"

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

help_rc=0
help=$(timeout 30 "$bin" --help 2>&1) || help_rc=$?
if [ "$help_rc" -eq 0 ] && [ -n "$help" ]; then
  echo "autolith-bridge --help: $(wc -l <<<"$help") lines"
  echo "autolith-bridge smoke test passed"
  exit 0
fi

version_rc=0
version=$(timeout 30 "$bin" --version 2>&1) || version_rc=$?
if [ "$version_rc" -eq 0 ] && [ -n "$version" ]; then
  echo "autolith-bridge --version: $(tr '\n' ' ' <<<"$version" | cut -c1-120)"
  echo "autolith-bridge smoke test passed"
  exit 0
fi

echo "--- --help (rc=$help_rc)" >&2
printf '%s\n' "$help" | head -n 10 >&2
echo "--- --version (rc=$version_rc)" >&2
printf '%s\n' "$version" | head -n 10 >&2
fail "neither --help nor --version produced a successful result"
