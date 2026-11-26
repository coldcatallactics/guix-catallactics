#!/usr/bin/env bash
# Verify that the Guix on PATH matches tests/channels-lock.
#
# `guix pull -C tests/channels-lock' should leave a profile whose Guix and
# Nonguix commits are exactly the pinned ones.  The build job once inherited
# brix-action's older Guix from PATH, which built substitutes for the wrong
# derivations even though `guix pull' had succeeded.  This check makes that
# failure immediate.
#
# Usage:
#   ./tests/check-channel-pins.sh           verify the running Guix
#   ./tests/check-channel-pins.sh --print   print the lock pins, one per line
#
# In GitHub Actions the script also insists that `guix' resolve to the pulled
# profile ($HOME/.config/guix/current/bin/guix), not an older profile left on
# PATH by the installer action.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

lock=tests/channels-lock
[ -f "$lock" ] || {
  echo "check-channel-pins: $lock is missing" >&2
  exit 1
}

pin_from_stream() {
  local name=$1
  awk -v name="$name" '
    !found && $0 ~ ("\\(name ." name "\\)") { found = 1; next }
    found && index($0, "(commit \"") {
      rest = substr($0, index($0, "(commit \"") + length("(commit \""))
      end = index(rest, "\"")
      if (end > 0) { print substr(rest, 1, end - 1); exit }
    }
  '
}

lock_pin() {
  local name=$1
  pin_from_stream "$name" < "$lock"
}

guix_pin=$(lock_pin guix)
nonguix_pin=$(lock_pin nonguix)

for pair in "guix:$guix_pin" "nonguix:$nonguix_pin"; do
  name=${pair%%:*}
  pin=${pair#*:}
  case "$pin" in
    *[!0-9a-f]*|"")
      echo "check-channel-pins: $name pin is not a 40-hex commit: '$pin'" >&2
      exit 1
      ;;
  esac
  [ ${#pin} -eq 40 ] || {
    echo "check-channel-pins: $name pin is not 40 hex: '$pin'" >&2
    exit 1
  }
done

if [ "${1:-}" = "--print" ]; then
  printf '%s\n%s\n' "$guix_pin" "$nonguix_pin"
  exit 0
fi
[ $# -eq 0 ] || {
  echo "usage: $0 [--print]" >&2
  exit 2
}

command -v guix >/dev/null 2>&1 || {
  echo "check-channel-pins: guix is not on PATH" >&2
  exit 1
}

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  expected_bin="$HOME/.config/guix/current/bin/guix"
  actual_bin=$(command -v guix)
  if [ "$actual_bin" != "$expected_bin" ]; then
    echo "check-channel-pins: guix resolves to $actual_bin, expected $expected_bin" >&2
    echo "  The pulled Guix must come before the installer's profile on PATH." >&2
    exit 1
  fi
fi

describe=$(guix describe -f channels)
# Parse the captured text: letting awk exit on the first match would close the
# pipe while `guix describe' is still writing, which trips `pipefail'.
actual_guix=$(pin_from_stream guix <<<"$describe")
actual_nonguix=$(pin_from_stream nonguix <<<"$describe")
version_output=$(guix --version)
version_guix=$(grep -oE '[0-9a-f]{40}' <<<"$version_output" | head -n1 || true)

failed=0
check_pin() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" != "$expected" ]; then
    echo "check-channel-pins: $name mismatch" >&2
    echo "  tests/channels-lock: $expected" >&2
    echo "  running Guix:        ${actual:-<missing>}" >&2
    failed=1
  else
    echo "  $name: $expected"
  fi
}

echo "==> pinned channels"
check_pin guix "$guix_pin" "$actual_guix"
check_pin nonguix "$nonguix_pin" "$actual_nonguix"
if [ "$version_guix" != "$guix_pin" ]; then
  echo "check-channel-pins: guix --version reports ${version_guix:-<no commit>}, lock pins $guix_pin" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "  Run: guix pull --allow-downgrades -C tests/channels-lock" >&2
  echo "  Then rerun this check in a new shell (PATH caches the old profile)." >&2
  exit 1
fi
echo "check-channel-pins: passed"
