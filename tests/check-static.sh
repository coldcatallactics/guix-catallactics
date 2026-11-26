#!/usr/bin/env bash
# Cheap checks that catch the failures users hit before a build starts:
#
#   * .guix-channel parses (a parenthesis slip there breaks every `guix pull');
#   * every .scm on Guile's module load path is a real module whose
#     define-module name matches its path under the channel root;
#   * every package module is `guix style' clean (STYLE_ADVISORY=1 downgrades
#     the formatting comparison to a warning);
#   * every define-public under catallactics/ resolves with --dry-run.
#
# The package names come from the define-public forms themselves, so adding a
# package needs no bookkeeping here.  A package that is documented as blocked
# (autolith-bridge at the time of writing) simply has no define-public and is
# therefore not expected by this script.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
shopt -s nullglob

fail() { echo "check-static: $*" >&2; exit 1; }

[ -f .guix-channel ] || fail ".guix-channel is missing"
modules=(catallactics/*.scm)
[ ${#modules[@]} -gt 0 ] || fail "no modules found under catallactics/"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- channel metadata -------------------------------------------------------
# The metadata file is not a module, so format a renamed copy: only the parse
# result matters, and `guix style' is the Scheme reader we already depend on.
echo "==> .guix-channel parses"
cp .guix-channel "$tmp/channel.scm"
if ! guix style -f "$tmp/channel.scm" >"$tmp/channel.log" 2>&1; then
  cat "$tmp/channel.log" >&2
  fail ".guix-channel does not parse; 'guix pull' would fail for every user"
fi

if grep -q 'nonguix' .guix-channel; then
  echo "==> .guix-channel declares the Nonguix dependency"
else
  echo "warning: .guix-channel does not mention nonguix" >&2
fi

# A declared dependency without an introduction is pulled unauthenticated.
echo "==> channel dependencies have introductions"
if ! guix repl -- >"$tmp/deps.log" 2>&1 <<'EOF'
(use-modules (guix channels))
(define read-meta (@@ (guix channels) read-channel-metadata))
(define deps (@@ (guix channels) channel-metadata-dependencies))
(call-with-input-file ".guix-channel"
  (lambda (port)
    (exit (if (every (lambda (channel)
                       (channel-introduction channel))
                     (deps (read-meta port)))
              0 1))))
EOF
then
  cat "$tmp/deps.log" >&2
  fail "a channel dependency has no introduction"
fi

# --- module shape -----------------------------------------------------------
# `guix pull' compiles every .scm file under the channel's `directory' (or
# under the repository root when `.guix-channel' omits it).  Parse that field
# instead of assuming catallactics/: with (directory "/") the module root is
# the repository root, and each file's define-module name must match its path
# relative to that root.  A mismatch makes `guix pull' look under the wrong
# name and breaks the channel for every user.
directory_script="$tmp/channel-directory.scm"
cat >"$directory_script" <<'EOF'
(use-modules (guix channels))
(define read-meta (@@ (guix channels) read-channel-metadata))
(define meta (call-with-input-file ".guix-channel" read-meta))
(display ((@@ (guix channels) channel-metadata-directory) meta))
(newline)
EOF
if ! channel_directory=$(guix repl -q "$directory_script" | tail -n1); then
  fail "could not read the channel directory from .guix-channel"
fi
case "$channel_directory" in
  /) module_root=. ;;
  /*) module_root=".${channel_directory}" ;;
  *) fail "unexpected channel directory: '$channel_directory'" ;;
esac

normalize_module_name() {
  tr -s '[:space:]' ' ' <<<"$1" | sed -e 's/^ //' -e 's/ $//'
}

echo "==> every .scm on the module path is a module (root: $channel_directory)"
while IFS= read -r f; do
  rel=${f#./}
  if [ "$module_root" != "." ]; then
    rel=${rel#"${module_root#./}/"}
  fi
  stem=${rel%.scm}
  expected=$(normalize_module_name "(${stem//\// })")

  actual=$(sed -n 's/^[[:space:]]*(define-module[[:space:]]*\(([^)]*)\).*/\1/p' \
    "$f" | head -n1)
  [ -n "$actual" ] ||
    fail "$f is a Scheme file but not a Guile module"
  actual=$(normalize_module_name "$actual")
  [ "$actual" = "$expected" ] ||
    fail "$f defines $actual but its path under $channel_directory requires $expected"
done < <(find "$module_root" -path ./.git -prune -o -type f -name '*.scm' -print)

# --- style ------------------------------------------------------------------
# Format copies, never the working tree: a check must leave no changes behind.
# Generated dependency tables, if any are ever added, are machine-written and
# skipped; everything hand-written is checked.
echo "==> guix style"
style_dir=$(mktemp -d "$tmp/style.XXXXXX")
style_files=()
for f in "${modules[@]}"; do
  if head -n 2 "$f" | grep -qiE 'generated|do not edit'; then
    echo "    skip generated: $f"
    continue
  fi
  cp "$f" "$style_dir/$(basename "$f")"
  style_files+=("$f")
done

if [ ${#style_files[@]} -gt 0 ]; then
  if ! guix style -f "$style_dir"/*.scm >"$tmp/style.log" 2>&1; then
    cat "$tmp/style.log" >&2
    fail "guix style could not format the package modules"
  fi
  style_bad=0
  for f in "${style_files[@]}"; do
    if ! cmp -s "$f" "$style_dir/$(basename "$f")"; then
      echo "--- $f differs from guix style output" >&2
      diff -u "$f" "$style_dir/$(basename "$f")" | head -n 30 >&2 || true
      style_bad=1
    fi
  done
  if [ "$style_bad" -eq 1 ]; then
    echo "check-static: package modules are not guix-style" >&2
    echo "  run 'guix style -f catallactics/*.scm' and commit the result" >&2
    if [ "${STYLE_ADVISORY:-0}" = 1 ]; then
      echo "  STYLE_ADVISORY=1: continuing anyway" >&2
    else
      fail "formatting check failed"
    fi
  fi
fi

# --- derivations ------------------------------------------------------------
names=$(grep -hoE '^\(define-public[[:space:]]+[^ )]+' "${modules[@]}" \
  | awk '{print $2}' | sort -u)
[ -n "$names" ] || fail "no define-public forms found under catallactics/"

if ! grep -qx 'autolith-bridge' <<<"$names"; then
  echo "note: autolith-bridge is not defined (blocked or not packaged yet)"
fi

# One Guix process for the whole channel; a failure is replayed per package so
# the log names the one that broke.
echo "==> derivations: $(printf '%s ' $names)"
if ! guix build -L . --dry-run $names; then
  bad=0
  for name in $names; do
    echo "==> derivation: $name"
    guix build -L . --dry-run "$name" || bad=1
  done
  if [ "$bad" -ne 0 ]; then
    fail "at least one package does not resolve"
  fi
fi

echo "check-static: passed"
