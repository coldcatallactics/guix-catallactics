#!/usr/bin/env bash
# Advisory `guix lint' run.  Lint has known false positives for repackaged
# vendor binaries (it asks for a source archive of a prebuilt release, for
# example), so this is not a merge gate.  The build is the gate; this surfaces
# review hints in the CI log.  Set LINT_STRICT=1 to make it fatal locally.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
shopt -s nullglob

modules=(catallactics/*.scm)
[ ${#modules[@]} -gt 0 ] || { echo "lint: no modules found" >&2; exit 0; }

names=$(grep -hoE '^\(define-public[[:space:]]+[^ )]+' "${modules[@]}" \
  | awk '{print $2}' | sort -u)
[ -n "$names" ] || { echo "lint: no packages found" >&2; exit 0; }

echo "==> guix lint: $(printf '%s ' $names)"
status=0
guix lint -L . $names || status=$?

if [ "$status" -ne 0 ]; then
  echo "lint: guix lint reported issues (advisory; the build is the gate)" >&2
  if [ "${LINT_STRICT:-0}" = 1 ]; then
    exit "$status"
  fi
fi
exit 0
