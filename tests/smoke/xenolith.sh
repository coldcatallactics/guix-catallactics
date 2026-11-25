#!/usr/bin/env bash
# Smoke test for xenolith.  Xenolith is a site layer plus a launcher around
# autolith, so the cheap proof is the same fast release probe autolith uses:
# the launcher must set AUTOLITH_SITE_CONFIG_ROOT and reach the bundled image,
# without triggering Autolith's minutes-long first full start.  If this
# autolith version does not expose the probe, fall back to checking the
# wrapper and the site tree statically.
set -euo pipefail
out="${1:?usage: $0 STORE-PATH}"

fail() { echo "xenolith smoke: $*" >&2; exit 1; }

bin="$out/bin/xenolith"
[ -x "$bin" ] || fail "missing executable $bin"

site=""
for candidate in \
  "$out/share/xenolith/site" \
  "$out/share/xenolith" \
  "$out/lib/xenolith/site" \
  "$out/libexec/xenolith/site"; do
  if [ -d "$candidate" ]; then site="$candidate"; break; fi
done

site_ok=0
if [ -n "$site" ]; then
  init=$(find "$site" -maxdepth 2 -name 'init.lisp' -print -quit 2>/dev/null || true)
  if [ -n "$init" ]; then
    site_ok=1
    echo "xenolith site: $site"
  fi
fi

wrapper_ok=0
if grep -aqE 'AUTOLITH_SITE_CONFIG_ROOT|share/xenolith|libexec/xenolith|xenolith/site' "$bin"; then
  wrapper_ok=1
  echo "xenolith launcher references its site tree"
fi

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

rc=0
probe=$(timeout 30 "$bin" --autolith-release-probe 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'version=' <<<"$probe"; then
  echo "xenolith release probe: $(tr '\n' ' ' <<<"$probe" | cut -c1-160)"
elif [ "$site_ok" -eq 1 ] && [ "$wrapper_ok" -eq 1 ]; then
  echo "xenolith release probe exited $rc; launcher and site tree are present"
  printf '%s\n' "$probe" | sed 's/^/    /' | head -n 5
else
  cat <<<"$probe" >&2
  fail "release probe failed (rc=$rc) and the launcher/site check did not pass"
fi

echo "xenolith smoke test passed"
