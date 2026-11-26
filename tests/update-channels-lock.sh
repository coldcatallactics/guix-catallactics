#!/usr/bin/env bash
# Advance the two commit pins in tests/channels-lock to the current
# upstream tips, leaving every introduction and comment untouched.
#
#   ./tests/update-channels-lock.sh
#   ./tests/update-channels-lock.sh --guix-commit <sha>
#   ./tests/update-channels-lock.sh --nonguix-commit <sha>
#
# --commit-1 is an alias for --guix-commit, useful when an upstream Guix
# regression has to be stepped around without touching Nonguix.
#
# The rewrite is a small Scheme tokenizer, not a sed on 40-hex strings: the
# comments in this file mention "(commit ...)" in prose, and a line-based edit
# would silently change the wrong thing.  Introductions are trust anchors and
# are never rewritten.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

lock=tests/channels-lock
guix_url=https://git.guix.gnu.org/guix.git
nonguix_url=https://gitlab.com/nonguix/nonguix
guix_commit=""
nonguix_commit=""

usage() {
  cat <<EOF
usage: $0 [--guix-commit SHA] [--nonguix-commit SHA]

With no arguments, resolves the Guix HEAD and Nonguix master tips with
git ls-remote and rewrites $lock.  Review the diff before committing.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --guix-commit|--commit-1)
      guix_commit=${2:?$1 needs a commit sha}; shift 2 ;;
    --nonguix-commit)
      nonguix_commit=${2:?$1 needs a commit sha}; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$lock" ] || { echo "missing $lock" >&2; exit 1; }

# CI runners have python3.  On a Guix machine it may only be available through
# a profile, so fall back to `guix shell python' rather than making the lock
# tool unusable locally.
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v guix >/dev/null 2>&1; then
  PYTHON=(guix shell python -- python3)
else
  echo "python3 is required (or guix, to enter a temporary python shell)" >&2
  exit 1
fi

if [ -z "$guix_commit" ]; then
  echo "==> resolving Guix HEAD"
  guix_commit=$(git ls-remote "$guix_url" HEAD | awk 'NR==1 {print $1}')
fi
if [ -z "$nonguix_commit" ]; then
  echo "==> resolving Nonguix master"
  nonguix_commit=$(git ls-remote "$nonguix_url" refs/heads/master | awk 'NR==1 {print $1}')
fi

for pair in "guix:$guix_commit" "nonguix:$nonguix_commit"; do
  name=${pair%%:*}
  value=${pair#*:}
  case "$value" in
    *[!0-9a-f]*|"") echo "$name commit is not 40 lowercase hex: '$value'" >&2; exit 1 ;;
  esac
  [ ${#value} -eq 40 ] || { echo "$name commit is not 40 hex: '$value'" >&2; exit 1; }
done

before=$(mktemp)
trap 'rm -f "$before"' EXIT
cp "$lock" "$before"

if ! "${PYTHON[@]}" - "$lock" "$guix_commit" "$nonguix_commit" <<'PY'
import re
import sys

path, guix_new, nonguix_new = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    src = fh.read()


def tokenize(text):
    """Yield (kind, value, start, end); skip comments but keep strings."""
    tokens = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if c == ";":
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if text.startswith("#|", i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("#|", i):
                    depth += 1
                    i += 2
                elif text.startswith("|#", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        if c in "()":
            tokens.append((c, c, i, i + 1))
            i += 1
            continue
        if c == '"':
            start = i
            i += 1
            chars = []
            while i < n:
                if text[i] == "\\":
                    chars.append(text[i:i + 2])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                chars.append(text[i])
                i += 1
            tokens.append(("string", "".join(chars), start, i))
            continue
        start = i
        while i < n and not text[i].isspace() and text[i] not in '();"':
            if text.startswith("#|", i) or text.startswith("|#", i):
                break
            i += 1
        if i == start:
            raise SystemExit("cannot tokenize at offset %d: %r" % (i, text[i:i + 20]))
        tokens.append(("atom", text[start:i], start, i))
    return tokens


tokens = tokenize(src)
current = None
replacements = []
seen = set()
i = 0
while i < len(tokens):
    if tokens[i][0] == "(":
        # (name 'guix) / (name guix)
        if (i + 3 < len(tokens)
                and tokens[i + 1][0] == "atom" and tokens[i + 1][1] == "name"
                and tokens[i + 2][0] == "atom" and tokens[i + 3][0] == ")"):
            name = tokens[i + 2][1].lstrip("'")
            if name in ("guix", "nonguix"):
                current = name
            i += 4
            continue
        # (commit "<40 hex>")
        if (i + 3 < len(tokens)
                and tokens[i + 1][0] == "atom" and tokens[i + 1][1] == "commit"
                and tokens[i + 2][0] == "string" and tokens[i + 3][0] == ")"):
            old = tokens[i + 2][1]
            if not re.fullmatch(r"[0-9a-f]{40}", old):
                raise SystemExit("commit value is not 40 lowercase hex: %r" % old)
            if current is None:
                raise SystemExit("found a commit before any channel name")
            if current in seen:
                raise SystemExit("more than one commit for channel %s" % current)
            new = guix_new if current == "guix" else nonguix_new
            seen.add(current)
            # String token positions include the quotes; replace the inside.
            replacements.append((tokens[i + 2][2] + 1, tokens[i + 2][3] - 1,
                                 new, current, old))
            i += 4
            continue
    i += 1

missing = {"guix", "nonguix"} - seen
if missing:
    raise SystemExit("no commit form found for: %s" % ", ".join(sorted(missing)))

for start, end, new, channel, old in sorted(replacements, reverse=True):
    src = src[:start] + new + src[end:]
    print("%s: %s -> %s" % (channel, old, new))

with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)
PY
then
  echo "rewrite failed; restoring $lock" >&2
  cp "$before" "$lock"
  exit 1
fi

if cmp -s "$before" "$lock"; then
  echo "no change (already at guix $guix_commit, nonguix $nonguix_commit)"
  exit 0
fi

# A rewrite that does not parse would break every user's pull, so check before
# showing the diff.  The lock is extensionless so `guix build -L .' does not
# scan it as a module; `guix style` still needs a .scm name, hence the copy.
if command -v guix >/dev/null 2>&1; then
  parse_dir=$(mktemp -d)
  cp "$lock" "$parse_dir/channels-lock.scm"
  if ! guix style -f "$parse_dir/channels-lock.scm" >/dev/null 2>&1; then
    rm -rf "$parse_dir"
    echo "the rewritten lock does not parse; restoring" >&2
    cp "$before" "$lock"
    exit 1
  fi
  rm -rf "$parse_dir"
else
  echo "warning: guix is not on PATH; skipped the parse check" >&2
fi

echo
echo "==> diff"
git diff --no-index -- "$before" "$lock" | tail -n +5 || true
echo
echo "guix:    $guix_commit"
echo "nonguix: $nonguix_commit"
echo
echo "Review the diff, then verify the pins resolve before committing:"
echo "  guix pull -n --allow-downgrades -C $lock"
echo "After pulling the new pins, verify the profile you are using:"
echo "  guix pull --allow-downgrades -C $lock"
echo "  ./tests/check-channel-pins.sh"
