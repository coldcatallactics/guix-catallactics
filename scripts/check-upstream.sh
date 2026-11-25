#!/usr/bin/env bash
# Compare the version pinned in each package module with the latest GitHub
# release of its upstream.  Advisory: network failures and rate limits are
# reported, not fatal, unless STRICT=1 is set.
#
#   ./scripts/check-upstream.sh
#   GITHUB_TOKEN=... ./scripts/check-upstream.sh
#   STRICT=1 ./scripts/check-upstream.sh   # exit 1 if any update is available
#
# The repository mapping is deliberately explicit: package names and upstream
# repository names do not always match, and a wrong guess would send someone
# to the wrong release page.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# python3 is on CI runners; on a Guix machine fall back to a temporary shell.
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v guix >/dev/null 2>&1; then
  PYTHON=(guix shell python -- python3)
else
  echo "check-upstream: python3 is required (or guix, for a temporary python shell)" >&2
  exit 1
fi

mapping=(
  "autolith-bin lambda-symbolics/autolith"
  "learnharness-bin amosblomqvist/learnharness"
  "opencode-bin anomalyco/opencode"
  "xenolith coldcatallactics/xenolith"
  "autolith-bridge chakanysystems/autolith-remote"
)

current_version() {
  local pkg=$1 file version
  file=$(grep -RlE "^\(define-public[[:space:]]+$pkg([[:space:]]|$)" \
           catallactics 2>/dev/null | head -n1)
  [ -n "$file" ] || return 0
  version=$(sed -n 's/^[[:space:]]*(version[[:space:]]*"\([^"]*\)").*/\1/p' "$file" \
    | head -n1)
  if [ -z "$version" ]; then
    # (version (git-version "0.2.0" "1" commit)) -- report the base version.
    version=$(sed -n \
      's/^[[:space:]]*(version[[:space:]]*(git-version[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$file" | head -n1)
  fi
  printf '%s\n' "$version"
}

github_get() {
  local url=$1
  local -a headers=(-H "Accept: application/vnd.github+json"
                    -H "User-Agent: guix-catallactics")
  local token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  [ -n "$token" ] && headers+=(-H "Authorization: Bearer $token")
  curl -fsSL --max-time 25 "${headers[@]}" "$url" 2>/dev/null
}

latest_tag() {
  local repo=$1 json tag
  json=$(github_get "https://api.github.com/repos/$repo/releases/latest") || true
  if [ -n "$json" ]; then
    tag=$("${PYTHON[@]}" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tag_name", ""))
except Exception:
    pass
' <<<"$json" 2>/dev/null)
  fi
  if [ -z "${tag:-}" ]; then
    # Some projects tag releases without publishing a GitHub release.
    json=$(github_get "https://api.github.com/repos/$repo/tags?per_page=1") || true
    [ -n "$json" ] || return 0
    tag=$("${PYTHON[@]}" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data[0]["name"] if data else "")
except Exception:
    pass
' <<<"$json" 2>/dev/null)
  fi
  printf '%s\n' "${tag#v}"
}

printf '%-18s %-12s %-12s %-14s %s\n' \
  PACKAGE CURRENT LATEST STATUS UPSTREAM
updates=0
ahead=0
unknown=0

for row in "${mapping[@]}"; do
  pkg=${row%% *}
  repo=${row#* }
  current=$(current_version "$pkg")
  latest=$(latest_tag "$repo")

  if [ -z "$current" ]; then
    status="not packaged"
    unknown=$((unknown + 1))
  elif [ -z "$latest" ]; then
    status="no release"
    unknown=$((unknown + 1))
  elif [ "$current" = "$latest" ]; then
    status="current"
  elif [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)" = "$current" ]; then
    # A pre-release or a tag that is newer than GitHub's "latest" release.
    status="ahead"
    ahead=$((ahead + 1))
  else
    status="update"
    updates=$((updates + 1))
  fi

  printf '%-18s %-12s %-12s %-14s %s\n' \
    "$pkg" "${current:--}" "${latest:--}" "$status" "$repo"
done

echo
if [ "$updates" -gt 0 ]; then
  echo "$updates update(s) available.  Bump the module with scripts/bump-package.sh."
elif [ "$unknown" -gt 0 ]; then
  echo "No update detected, but $unknown package(s) could not be checked completely."
else
  echo "All packaged versions match their latest upstream release."
fi
if [ "$ahead" -gt 0 ]; then
  echo "$ahead package(s) are newer than the GitHub 'latest release' tag (pre-release or untagged)."
fi

if [ "${STRICT:-0}" = 1 ] && [ "$updates" -gt 0 ]; then
  exit 1
fi
exit 0
