#!/usr/bin/env bash
# SECRET GUARD: fail before a private key or access token reaches git.
#
# The channel publishes prebuilt binaries and a substitute signing public key,
# so the repository is public.  The private half of the signing key must only
# ever exist in the GUIX_SIGNING_KEY repository secret.  This guard is run by
# CI on every push and pull request, and can be used locally before committing:
#
#   ./.github/scripts/secret-guard.sh            # scan tracked + untracked files
#   ./.github/scripts/secret-guard.sh staged     # scan the index only
#   ./.github/scripts/secret-guard.sh file PATH  # scan one file
#
# It deliberately prints only file names and line numbers, never the matching
# text, so a red CI log cannot itself leak the value it caught.
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$root" ]; then
  root=$(cd "$(dirname "$0")/../.." && pwd)
fi
cd "$root" || exit 2

mode=${1:-check}
case "$mode" in
  check|staged|file) ;;
  -h|--help)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: $0 [check|staged|file PATH]" >&2
    exit 2
    ;;
esac

# The guard necessarily contains the patterns it searches for; do not flag
# itself.  SECRET_GUARD_SKIP is a colon-separated list of additional globs.
self_rel=".github/scripts/secret-guard.sh"
skip_globs=("$self_rel")
if [ -n "${SECRET_GUARD_SKIP:-}" ]; then
  IFS=: read -r -a extra <<<"$SECRET_GUARD_SKIP"
  skip_globs+=("${extra[@]}")
fi

skipped() {
  local path=$1 glob
  for glob in "${skip_globs[@]}"; do
    # shellcheck disable=SC2053
    [[ $path == $glob ]] && return 0
  done
  return 1
}

# label|extended-regular-expression.  Keep the expressions broad enough to
# catch a real credential and narrow enough not to flag prose in the docs.
patterns=(
  'PEM private key|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
  'Guix signing key|\(private-key[[:space:]]*\(ecc'
  'age secret key|AGE-SECRET-KEY-1[0-9A-Z]{20,}'
  'GitHub token|(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
  'OpenAI-style key|sk-[A-Za-z0-9]{20,}'
  'AWS access key|AKIA[0-9A-Z]{16}'
  'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
)

# A line that only demonstrates the shape of a key is documentation, not a
# secret.  This is intentionally conservative: a real key never contains these
# words, while every example in a README does.
placeholder_re='example|placeholder|redacted|dummy|sample|your[_-]|not-a-real|\.\.\.|<[^>]+>'

# Private-key file names are suspicious even when the content is unreadable.
secret_name_re='(^|/)(id_(rsa|dsa|ecdsa|ed25519)|signing-key\.sec|.*\.(pem|key|p12|pfx|sec))$'

hits=0
declare -a files=()

collect_files() {
  local mode=$1
  case "$mode" in
    file)
      files=("${2:?file mode needs a path}")
      ;;
    staged)
      while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(git diff --cached --name-only --diff-filter=ACMR -z)
      ;;
    check)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' f; do files+=("$f"); done \
          < <(git ls-files -z --cached --others --exclude-standard)
      else
        while IFS= read -r -d '' f; do files+=("${f#./}"); done \
          < <(find . -path ./.git -prune -o -type f -print0)
      fi
      ;;
  esac
}

report() {
  local path=$1 line=${2:-} what=$3
  if [ -n "$line" ]; then
    echo "::error file=$path,line=$line::possible $what" >&2
    echo "secret-guard: $path:$line: possible $what" >&2
  else
    echo "::error file=$path::possible $what" >&2
    echo "secret-guard: $path: possible $what" >&2
  fi
  hits=$((hits + 1))
}

scan_file() {
  local path=$1
  [ -f "$path" ] || return 0
  skipped "$path" && return 0

  # A tracked private-key file is a finding regardless of its content.
  if [[ $path =~ $secret_name_re ]] && [[ $path != *.pub ]]; then
    report "$path" "" "private-key file name"
    return 0
  fi

  # -I skips binary files, which cannot be checked line by line anyway.
  grep -Iq . "$path" 2>/dev/null || return 0

  local entry label regex lines line
  for entry in "${patterns[@]}"; do
    label=${entry%%|*}
    regex=${entry#*|}
    # Collect line numbers of matches that are not documentation examples.
    lines=$(grep -nIE -- "$regex" "$path" 2>/dev/null \
      | grep -viE -- "$placeholder_re" \
      | cut -d: -f1 || true)
    [ -n "$lines" ] || continue
    for line in $lines; do
      report "$path" "$line" "$label"
    done
  done
}

collect_files "$mode" "${2:-}"
for f in "${files[@]}"; do
  scan_file "$f"
done

if [ "$hits" -ne 0 ]; then
  cat >&2 <<'EOF'
secret-guard: refusing to continue.
Remove the value from the working tree (and from git history if it was ever
committed), rotate it upstream, and keep private keys in repository secrets.
The substitute signing public key belongs at .guix-substitutes.pub; its
private half belongs only in the GUIX_SIGNING_KEY secret.
EOF
  exit 1
fi

echo "secret-guard: clean (mode=$mode, files=${#files[@]})"
