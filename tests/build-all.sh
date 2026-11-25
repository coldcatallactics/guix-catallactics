#!/usr/bin/env bash
# Build every package defined in catallactics/ and run its smoke test.
#
# Source packages are built first, `*-bin' packages afterwards.  A source
# build is the one that can fail for a packaging reason (patch, phase,
# dependency); a `*-bin' build mostly proves a download and a wrapper.  Every
# package is attempted even after one fails, so a single broken definition
# does not hide the others.
#
# The output paths are appended to $GUIX_BUILT_PATHS (one per line) for
# tests/publish-substitutes.sh.  Set PACKAGES to narrow the run:
#
#   PACKAGES="xenolith autolith-bin" ./tests/build-all.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
shopt -s nullglob

fail() { echo "build-all: $*" >&2; exit 1; }

modules=(catallactics/*.scm)
[ ${#modules[@]} -gt 0 ] || fail "no modules found under catallactics/"

if [ -n "${PACKAGES:-}" ]; then
  names=$PACKAGES
else
  all=$(grep -hoE '^\(define-public[[:space:]]+[^ )]+' "${modules[@]}" \
    | awk '{print $2}' | sort -u)
  [ -n "$all" ] || fail "no define-public forms found under catallactics/"
  source_pkgs=$(printf '%s\n' $all | grep -vE -- '-bin$' || true)
  bin_pkgs=$(printf '%s\n' $all | grep -E -- '-bin$' || true)
  names="$(printf '%s\n' $source_pkgs) $(printf '%s\n' $bin_pkgs)"
fi

[ -n "${names// /}" ] || fail "no packages selected"

if [ -n "${GUIX_BUILT_PATHS:-}" ]; then
  mkdir -p "$(dirname "$GUIX_BUILT_PATHS")"
  : >> "$GUIX_BUILT_PATHS"
fi

failed=()
for name in $names; do
  echo "==> build: $name"
  # Progress and errors go to stderr; stdout is the store path list.
  if ! outs=$(guix build -L . "$name"); then
    failed+=("$name (build)")
    continue
  fi

  if [ -n "${GUIX_BUILT_PATHS:-}" ]; then
    for out in $outs; do
      printf '%s\n' "$out" >> "$GUIX_BUILT_PATHS"
    done
  fi

  smoke="tests/smoke/$name.sh"
  if [ -x "$smoke" ]; then
    echo "==> smoke: $name"
    # Pass all outputs; the smoke scripts use the first (the `out' path).
    if ! "$smoke" $outs; then
      failed+=("$name (smoke)")
    fi
  else
    echo "    no smoke test at $smoke"
  fi
done

if [ -n "${GUIX_BUILT_PATHS:-}" ] && [ -f "$GUIX_BUILT_PATHS" ]; then
  sort -u "$GUIX_BUILT_PATHS" -o "$GUIX_BUILT_PATHS"
  echo "==> recorded $(wc -l < "$GUIX_BUILT_PATHS") store paths in $GUIX_BUILT_PATHS"
fi

if [ ${#failed[@]} -ne 0 ]; then
  echo "build-all: failed: ${failed[*]}" >&2
  exit 1
fi
echo "build-all: all requested packages built and smoke-tested"
