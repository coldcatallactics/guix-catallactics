#!/usr/bin/env bash
# Update one package's (version ...) and source hash in its module.
#
#   ./scripts/bump-package.sh PACKAGE VERSION HASH
#   ./scripts/bump-package.sh --version-only PACKAGE VERSION
#
# HASH is the Guix/nix-base32 source hash, i.e. what `guix hash FILE' prints by
# default.  A leading "sha256:" or "base32:" is accepted and stripped.  The
# script updates the first (version ...) -- including the base string of a
# (version (git-version "X" ...)) form -- and the first (sha256 (base32 ...))
# or (base32 ...) inside that package's define-public form; comments and the
# rest of the module are left byte-for-byte unchanged.
#
# Getting the hash:
#   guix download https://…/release.tar.gz
#   guix hash /path/to/release.tar.gz
# or, for a source checkout:
#   guix hash -x /path/to/checkout
#
# For a package whose version is (git-version "X" "N" COMMIT), this updates
# the base version X; the commit pin remains a deliberate separate edit.
#
# This helper deliberately does not download or guess a URL: a wrong URL is
# worse than an explicit hash supplied by the packager.  It also does not edit
# a package that is only documented as blocked and has no define-public.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

version_only=0
if [ "${1:-}" = --version-only ]; then
  version_only=1
  shift
fi

if [ $# -lt 2 ]; then
  usage >&2
  exit 2
fi

pkg=$1
version=$2
hash=${3:-}
if [ "$version_only" -eq 0 ] && [ -z "$hash" ]; then
  echo "bump-package: HASH is required (or use --version-only)" >&2
  usage >&2
  exit 2
fi
hash=${hash#sha256:}
hash=${hash#base32:}

file=$(grep -RlE "^\(define-public[[:space:]]+$pkg([[:space:]]|$)" \
         catallactics 2>/dev/null | head -n1)
if [ -z "$file" ]; then
  echo "bump-package: no define-public $pkg under catallactics/" >&2
  echo "available packages:" >&2
  grep -rhoE '^\(define-public[[:space:]]+[^ )]+' catallactics/*.scm 2>/dev/null \
    | awk '{print "  " $2}' >&2
  exit 1
fi

before=$(mktemp)
trap 'rm -f "$before"' EXIT
cp "$file" "$before"

# python3 is on CI runners; on a Guix machine use a temporary python shell.
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v guix >/dev/null 2>&1; then
  PYTHON=(guix shell python -- python3)
else
  echo "bump-package: python3 is required (or guix, for a temporary python shell)" >&2
  exit 1
fi

if ! "${PYTHON[@]}" - "$file" "$pkg" "$version" "$hash" "$version_only" <<'PY'
import re
import sys

path, pkg, version, new_hash, version_only = sys.argv[1:6]
version_only = version_only == "1"
with open(path, encoding="utf-8") as fh:
    src = fh.read()


def form_end(text, start):
    """Return the index just past the form opening at START."""
    depth = 0
    i, n = start, len(text)
    in_string = False
    escape = False
    line_comment = False
    block_depth = 0
    while i < n:
        c = text[i]
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_depth:
            if text.startswith("#|", i):
                block_depth += 1
                i += 2
            elif text.startswith("|#", i):
                block_depth -= 1
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_string = False
            i += 1
            continue
        if c == ";":
            line_comment = True
            i += 1
            continue
        if text.startswith("#|", i):
            block_depth = 1
            i += 2
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit("unbalanced form starting at offset %d" % start)


m = re.search(r"(?m)^\(define-public[ \t]+" + re.escape(pkg) + r"(?=[ \t]|$)", src)
if not m:
    raise SystemExit("define-public %s not found" % pkg)
start = m.start()
end = form_end(src, start)
block = src[start:end]

vm = re.search(r'\(\s*version\s+"([^"]*)"\s*\)', block)
if not vm:
    # (version (git-version "0.2.0" "1" commit)) -- update the base version.
    vm = re.search(
        r'\(\s*version\s+\(\s*git-version\s+"([^"]*)"', block)
if not vm:
    raise SystemExit("no (version ...) or (version (git-version ...)) form in %s" % pkg)

replacements = []
if vm.group(1) != version:
    replacements.append((start + vm.start(1), start + vm.end(1), version))

if not version_only:
    if not re.fullmatch(r"[0-9a-z]{52}", new_hash):
        raise SystemExit(
            "HASH must be 52 nix-base32 characters (guix hash output); got %r"
            % new_hash)
    hm = re.search(
        r'\(\s*sha256\s*\(\s*base32\s+"([^"]*)"\s*\)\s*\)', block)
    if not hm:
        hm = re.search(r'\(\s*base32\s+"([^"]*)"\s*\)', block)
    if not hm:
        raise SystemExit("no (base32 ...) source hash in %s" % pkg)
    if hm.group(1) != new_hash:
        replacements.append((start + hm.start(1), start + hm.end(1), new_hash))
    elif not replacements:
        print("NO-EDIT")
        sys.exit(0)
else:
    if not replacements:
        print("NO-EDIT")
        sys.exit(0)

for begin, finish, value in sorted(replacements, reverse=True):
    src = src[:begin] + value + src[finish:]

with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)
print("updated %s: version %s%s" % (
    pkg, version, "" if version_only else ", hash %s" % new_hash))
PY
then
  echo "bump-package: rewrite failed; restoring $file" >&2
  cp "$before" "$file"
  exit 1
fi

if cmp -s "$before" "$file"; then
  echo "bump-package: no change"
  exit 0
fi

# A version bump that no longer parses is worse than no bump at all.
if command -v guix >/dev/null 2>&1; then
  parse_dir=$(mktemp -d)
  cp "$file" "$parse_dir/$(basename "$file")"
  if ! guix style -f "$parse_dir/$(basename "$file")" >/dev/null 2>&1; then
    rm -rf "$parse_dir"
    echo "bump-package: $file does not parse after the edit; restoring" >&2
    cp "$before" "$file"
    exit 1
  fi
  rm -rf "$parse_dir"
fi

echo
echo "==> diff"
git diff --no-index -- "$before" "$file" | tail -n +5 || true
echo
echo "Next: guix build -L . $pkg"
echo "      ./scripts/check-upstream.sh"
