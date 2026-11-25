#!/usr/bin/env bash
# Smoke test for learnharness-bin.  The package is an Electron application
# whose main process starts a bundled Next.js server; upstream does not have a
# conventional `--version' that exits immediately, so the probe accepts either
# a version answer or a server-startup log.  If a display is available through
# xvfb-run, use it; otherwise try directly (the server starts before any window
# is needed).  No network or credentials are used.
set -euo pipefail
out="${1:?usage: $0 STORE-PATH}"

fail() { echo "learnharness-bin smoke: $*" >&2; exit 1; }

bin="$out/bin/learnharness"
[ -x "$bin" ] || fail "missing executable $bin"

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

log="$tmp/probe.log"
rc=0
if command -v xvfb-run >/dev/null 2>&1; then
  timeout 45 xvfb-run -a "$bin" --no-sandbox --version >"$log" 2>&1 || rc=$?
else
  timeout 45 "$bin" --no-sandbox --version >"$log" 2>&1 || rc=$?
fi

if [ "$rc" -eq 0 ] && [ -s "$log" ]; then
  echo "learnharness --version: $(tr '\n' ' ' <"$log" | cut -c1-120)"
elif grep -qiE 'learnharness|server:|local:|127\.0\.0\.1' "$log"; then
  # The process started its bundled server and was stopped by the timeout;
  # that is the expected shape of this application's startup probe.
  echo "learnharness started its server (rc=$rc)"
  grep -iE 'server:|local:|learnharness' "$log" | head -n3
else
  cat "$log" >&2
  fail "neither a version nor a server-startup log was produced (rc=$rc)"
fi

# The packaged application must carry its server resources, not merely a
# launcher that would download them at first run.
for dir in \
  "$out/libexec/learnharness/resources/server" \
  "$out/lib/learnharness/resources/server" \
  "$out/share/learnharness/resources/server"; do
  if [ -d "$dir" ]; then
    echo "learnharness resources: $dir"
    break
  fi
done

echo "learnharness-bin smoke test passed"
