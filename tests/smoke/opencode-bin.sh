#!/usr/bin/env bash
# Smoke test for opencode-bin: the upstream Bun-compiled binary is patched to
# Guix's loader and wrapped so it starts without an FHS /lib64.  `--version'
# exercises the loader, the wrapper and the CLI; `--help' loads the full
# command tree.  No credentials are needed and no network is assumed.
set -euo pipefail
out="${1:?usage: $0 STORE-PATH}"

fail() { echo "opencode-bin smoke: $*" >&2; exit 1; }

bin=""
for candidate in opencode opencode-bin; do
  if [ -x "$out/bin/$candidate" ]; then bin="$out/bin/$candidate"; break; fi
done
[ -n "$bin" ] || fail "missing $out/bin/opencode"

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

version=$(timeout 30 "$bin" --version 2>&1) ||
  fail "--version failed: $version"
case "$version" in
  *opencode*[0-9]*|*[0-9]*.[0-9]*) ;;
  *) fail "unexpected --version output: $version" ;;
esac
echo "opencode --version: $(tr '\n' ' ' <<<"$version" | cut -c1-120)"

help=$(timeout 30 "$bin" --help 2>&1) ||
  fail "--help failed: $help"
grep -qiE 'usage|opencode' <<<"$help" ||
  fail "--help printed no recognizable usage text"
echo "opencode --help: $(wc -l <<<"$help") lines"

echo "opencode-bin smoke test passed"
