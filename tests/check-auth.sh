#!/usr/bin/env bash
# Check the channel-authentication setup without making a new channel
# unmergeable before its first signed commit exists.
#
#   .guix-authorizations present?   parse it and, when the introduction is
#                                   configured, run `guix git authenticate'.
#   absent?                         report how to initialize it and exit 0.
#
# The introduction can be supplied as repository variables in CI:
#   GUIX_AUTH_COMMIT   the initial commit named in the README/announcement
#   GUIX_AUTH_SIGNER   the OpenPGP fingerprint of that commit's signer
# Locally, the same values may live in .git/config:
#   [guix "authentication"]
#       commit = ...
#       signer = ...
#
# Environment:
#   REQUIRE_AUTH=1   fail when .guix-authorizations is absent
#   AUTH_STRICT=1    also fail when the README does not document authentication
#   AUTH_SOFT=1      report a failed `guix git authenticate' but do not fail
#   --strict         shorthand for REQUIRE_AUTH=1 AUTH_STRICT=1
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "${1:-}" = --strict ]; then
  REQUIRE_AUTH=1
  AUTH_STRICT=1
fi

warn() { echo "check-auth: $*" >&2; }
fail() { echo "check-auth: $*" >&2; exit 1; }

auth_file=.guix-authorizations
readme=""
for candidate in README.org README.md README.rst README; do
  if [ -f "$candidate" ]; then readme=$candidate; break; fi
done

if [ ! -f "$auth_file" ]; then
  warn "no $auth_file yet: channel authentication is not initialized"
  warn "run ./scripts/init-channel-auth.sh, commit $auth_file with a signed"
  warn "commit, and export the public key to the orphan 'keyring' branch"
  if [ "${REQUIRE_AUTH:-0}" = 1 ]; then
    fail "$auth_file is required"
  fi
  exit 0
fi

[ -s "$auth_file" ] || fail "$auth_file is empty"
grep -q '(authorizations' "$auth_file" ||
  fail "$auth_file does not contain an (authorizations ...) form"
# The file authorizes OpenPGP fingerprints, quoted either as 40 hex digits or
# as ten space-separated groups of four.  It does not use a key-fingerprint
# field; that is guix/git-authenticate's internal representation.
grep -Eq '"[0-9A-Fa-f]{40}"|"[0-9A-Fa-f]{4}([[:space:]]+[0-9A-Fa-f]{4}){9}"' "$auth_file" ||
  fail "$auth_file authorizes no OpenPGP fingerprint"

# Parse it the same way guix pull will.  The file is not a module, so format a
# copy and only use the exit status.
if command -v guix >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cp "$auth_file" "$tmp/authorizations.scm"
  if ! guix style -f "$tmp/authorizations.scm" >"$tmp/parse.log" 2>&1; then
    cat "$tmp/parse.log" >&2
    fail "$auth_file does not parse"
  fi
  echo "==> $auth_file parses"
else
  warn "guix is not on PATH; skipped the syntax check of $auth_file"
fi

if [ -z "$readme" ]; then
  warn "no README found; authentication is not documented"
  if [ "${AUTH_STRICT:-0}" = 1 ]; then
    fail "README documenting authentication is required"
  fi
elif ! grep -qiE 'guix git authenticate|init-channel-auth\.sh|channel introduction' "$readme"; then
  warn "$readme does not document channel authentication"
  if [ "${AUTH_STRICT:-0}" = 1 ]; then
    fail "$readme must document channel authentication"
  fi
else
  echo "==> $readme documents channel authentication"
fi

# Running the real authentication is optional: a fresh clone has no
# introduction in .git/config, and CI has no way to guess the initial signed
# commit.  When the values are provided, this is the check that matters.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "==> no commits yet; skipped guix git authenticate"
  exit 0
fi

auth_commit=${GUIX_AUTH_COMMIT:-}
auth_signer=${GUIX_AUTH_SIGNER:-}
if [ -z "$auth_commit" ]; then
  auth_commit=$(git config --get guix.authentication.commit 2>/dev/null | head -n1 || true)
fi
if [ -z "$auth_signer" ]; then
  auth_signer=$(git config --get guix.authentication.signer 2>/dev/null | head -n1 || true)
fi

if [ -z "$auth_commit" ] || [ -z "$auth_signer" ]; then
  echo "==> skipped guix git authenticate (no introduction configured)"
  echo "    set GUIX_AUTH_COMMIT and GUIX_AUTH_SIGNER, or add"
  echo "    [guix \"authentication\"] commit/signer to .git/config"
  exit 0
fi

echo "==> guix git authenticate $auth_commit $auth_signer"
if guix git authenticate "$auth_commit" "$auth_signer"; then
  echo "check-auth: authenticated"
else
  if [ "${AUTH_SOFT:-0}" = 1 ]; then
    warn "guix git authenticate failed (AUTH_SOFT=1: continuing)"
  else
    fail "guix git authenticate failed"
  fi
fi
