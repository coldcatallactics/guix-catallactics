#!/usr/bin/env bash
# Consumer-side test of the hybrid substitute mirror.
#
# This runs on a fresh runner that built nothing.  It proves four things:
#
#   1. the packages are not available from the official/Nonguix substitutes,
#      so a successful install really depends on this channel's mirror;
#   2. the Pages narinfo exists and its URL points at the GitHub release
#      assets, not back at GitHub Pages;
#   3. Guix accepts the narinfo signature and downloads the nar from the
#      release;
#   4. the installed program runs (its smoke test).
#
# Every package here is large (100+ MiB compressed), so the default is a full
# install of ONE package.  `opencode-bin' is the default because its substitute
# is smaller than its upstream tarball and it has no graft-heavy dependency
# graph.  Override with TEST_PACKAGES="pkg ..." or MAX_TEST_PACKAGES=N.
#
# Environment:
#   MIRROR_URL          Pages substitute URL
#   NAR_BASE_URL        expected public nar base; when set, every URL is
#                       required to start with it
#   TEST_PACKAGES       space-separated package names to consider
#   MAX_TEST_PACKAGES   how many to install (default 1)
#   SKIP_AUTH=1         assume the key is already authorized (local rerun)
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

MIRROR="${MIRROR_URL:-https://coldcatallactics.github.io/guix-catallactics}"
MIRROR=${MIRROR%/}
UPSTREAMS="${UPSTREAM_SUBSTITUTES:-https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org}"
URLS="$UPSTREAMS $MIRROR"
MAX_TEST_PACKAGES="${MAX_TEST_PACKAGES:-1}"

fail() { echo "check-substitutes: $*" >&2; exit 1; }

[ -f .guix-substitutes.pub ] ||
  fail ".guix-substitutes.pub is missing; the mirror has no public key to authorize"

# --- 1. authorize the signing key for the local daemon ----------------------
guix_bin=$(command -v guix) || fail "guix is not on PATH"
key_hex=$(tr -d '\n' < .guix-substitutes.pub \
  | sed -n 's/.*(q #\([0-9A-Fa-f]*\)#.*/\1/p')
[ -n "$key_hex" ] || fail "could not read the public key from .guix-substitutes.pub"

if [ "${SKIP_AUTH:-0}" = 1 ]; then
  echo "==> SKIP_AUTH=1: assuming the signing key is already authorized"
else
  if [ "$(id -u)" -eq 0 ]; then
    sudo_cmd=()
  elif sudo -n true 2>/dev/null; then
    sudo_cmd=(sudo)
  else
    fail "passwordless sudo is required to authorize the key (or set SKIP_AUTH=1)"
  fi

  if "${sudo_cmd[@]}" grep -q "$key_hex" /etc/guix/acl 2>/dev/null; then
    echo "==> signing key already authorized"
  else
    echo "==> authorizing .guix-substitutes.pub"
    "${sudo_cmd[@]}" "$guix_bin" archive --authorize < .guix-substitutes.pub
    # The daemon caches the ACL; a restart makes it read the new key.  Failure
    # to restart is not fatal here -- the substitute attempt below will fail
    # loudly if the daemon never saw the key.
    if command -v systemctl >/dev/null 2>&1; then
      "${sudo_cmd[@]}" systemctl restart guix-daemon 2>/dev/null || \
        echo "warning: could not restart guix-daemon; continuing" >&2
    fi
  fi
fi

# --- 2. the Pages metadata endpoint is alive --------------------------------
info=""
for _ in $(seq 1 180); do
  if info=$(curl -sf "$MIRROR/nix-cache-info" 2>/dev/null); then break; fi
  sleep 2
done
[ -n "$info" ] || fail "$MIRROR/nix-cache-info is not reachable"
grep -q '^StoreDir=/gnu/store$' <<<"$info" ||
  fail "$MIRROR/nix-cache-info is not a Guix cache"
echo "==> mirror metadata: $(tr '\n' ' ' <<<"$info")"

mirror_pubkey=$(curl -sf "$MIRROR/pubkey") ||
  fail "$MIRROR/pubkey is missing"
grep -q 'public-key' <<<"$mirror_pubkey" ||
  fail "$MIRROR/pubkey is not a Guix public key"
# Authorize the key that Pages actually publishes, not merely a local copy.
if [ "$(printf '%s\n' "$mirror_pubkey")" != "$(cat .guix-substitutes.pub)" ]; then
  fail "$MIRROR/pubkey differs from .guix-substitutes.pub"
fi

# --- 3. find the package names this channel defines -------------------------
shopt -s nullglob
modules=(catallactics/*.scm)
[ ${#modules[@]} -gt 0 ] || fail "no modules under catallactics/"
available=$(grep -hoE '^\(define-public[[:space:]]+[^ )]+' "${modules[@]}" \
  | awk '{print $2}' | sort -u)
[ -n "$available" ] || fail "no define-public forms found under catallactics/"

if [ -n "${TEST_PACKAGES:-}" ]; then
  candidates=$TEST_PACKAGES
else
  candidates="opencode-bin"
fi

# --- 4. per-package proof, without building anything ------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$work/usable"

for pkg in $candidates; do
  if ! grep -Fxq "$pkg" <<<"$available"; then
    echo "==> skip $pkg: not defined in this channel"
    continue
  fi

  echo "==> probing $pkg"
  dry="$(guix build -L . --dry-run --substitute-urls="$UPSTREAMS" "$pkg" 2>&1 || true)"

  # The package's own output must not be substitutable upstream.  Its
  # dependencies may download from the official farms; that is fine.
  if grep -E "^[[:space:]]*/gnu/store/[0-9a-z]+-$pkg-[0-9]" <<<"$dry" | grep -qv '\.drv$'; then
    fail "$pkg already has an upstream substitute; this test would prove nothing"
  fi

  # Ask Guix for the package derivation directly.  Parsing the dry-run output
  # is fragile: xenolith also prints an `xenolith-...-checkout.drv' first.
  drv=$(guix build -L . -d "$pkg" 2>/dev/null | head -n1 || true)
  if [ -z "$drv" ]; then
    echo "==> skip $pkg: guix build -d named no derivation"
    continue
  fi

  out=$(grep -oE '\("out",[[:space:]]*"/gnu/store/[0-9a-z]+-[^"]+"' "$drv" \
    | head -n1 | sed -E 's/^\("out",[[:space:]]*"//; s/"$//' || true)
  if [ -z "$out" ]; then
    echo "==> skip $pkg: $drv names no out output"
    continue
  fi

  base=$(basename "$out")
  hash=${base%%-*}
  # Pages deployments can take a minute to become visible even after the
  # action returns; retry a 404 before declaring the item absent.
  narinfo=""
  for _ in $(seq 1 60); do
    if narinfo=$(curl -sf "$MIRROR/$hash.narinfo" 2>/dev/null); then
      break
    fi
    sleep 5
  done
  if [ -z "$narinfo" ]; then
    echo "==> skip $pkg: $MIRROR/$hash.narinfo is absent"
    continue
  fi

  url=$(sed -n 's/^URL:[[:space:]]*//p' <<<"$narinfo" | head -n1)
  compression=$(sed -n 's/^Compression:[[:space:]]*//p' <<<"$narinfo" | head -n1)
  [ -n "$url" ] || fail "$pkg: narinfo has no URL field"
  case "$url" in
    http://*|https://*) ;;
    *) fail "$pkg: narinfo URL is not absolute: $url" ;;
  esac
  case "$url" in
    "$MIRROR"/*) fail "$pkg: nar URL still points at Pages: $url" ;;
  esac
  if [ -n "${NAR_BASE_URL:-}" ]; then
    case "$url" in
      "${NAR_BASE_URL%/}"/*) ;;
      *) fail "$pkg: nar URL does not use NAR_BASE_URL: $url" ;;
    esac
  fi
  [ "$compression" = gzip ] || fail "$pkg: expected gzip compression, got '$compression'"

  # A HEAD request proves the external object is public and present without
  # downloading hundreds of megabytes just to discard them.  Release-asset
  # URLs redirect and can take a moment to become visible.
  reachable=0
  for _ in $(seq 1 12); do
    if curl -fsSIL "$url" >/dev/null 2>&1; then reachable=1; break; fi
    sleep 5
  done
  [ "$reachable" = 1 ] ||
    fail "$pkg: nar URL is not reachable: $url"
  echo "    nar: $url"

  # With the mirror authorized, the same output should flip to a download.
  # Graft-heavy packages can still show a graft plan here; the install step
  # below is the authoritative proof that the substitute was used.
  dry_mirror="$(guix build -L . --dry-run --substitute-urls="$URLS" "$pkg" 2>&1 || true)"
  if grep -E "^[[:space:]]*/gnu/store/[0-9a-z]+-$pkg-[0-9]" <<<"$dry_mirror" | grep -qv '\.drv$'; then
    echo "    mirror would download $pkg"
  else
    echo "    warning: dry-run did not name a substitute; relying on install" >&2
  fi

  nar_size=$(sed -n 's/^NarSize:[[:space:]]*//p' <<<"$narinfo" | head -n1)
  printf '%s\t%s\t%s\n' "${nar_size:-0}" "$pkg" "$out" >> "$work/usable"
done

# Smallest first: installing one package is the point, not downloading all of
# them.  NarSize is the uncompressed size, which is a good relative ordering.
mapfile -t chosen < <(sort -n "$work/usable" | head -n "$MAX_TEST_PACKAGES")
[ ${#chosen[@]} -gt 0 ] ||
  fail "no package from this channel is usable from the mirror (check Pages and GitHub Releases)"

# --- 5. install from Pages + Releases and run the smoke test ----------------------
profile_dir=$(mktemp -d)
trap 'rm -rf "$work" "$profile_dir"' EXIT
profile="$profile_dir/profile"

for line in "${chosen[@]}"; do
  IFS=$'\t' read -r _ pkg out <<<"$line"
  echo "==> installing $pkg from the mirror"
  log="$work/install-$pkg.log"
  if ! GUIX_PACKAGE_PATH="$PWD" \
       guix package -p "$profile" --install "$pkg" \
         --substitute-urls="$URLS" >"$log" 2>&1; then
    cat "$log" >&2
    fail "$pkg failed to install"
  fi
  grep -qiE 'substitut|downloading from' "$log" ||
    fail "$pkg install did not substitute (the mirror may be unusable)"
  [ -e "$out" ] || fail "$pkg: expected store path $out is missing after install"

  smoke="tests/smoke/$pkg.sh"
  if [ -x "$smoke" ]; then
    echo "==> smoke: $pkg"
    "$smoke" "$out"
  else
    echo "==> no smoke test for $pkg; checking bin/ only"
    [ -d "$out/bin" ] || fail "$pkg: $out/bin is missing"
  fi
done

echo "check-substitutes: passed (${#chosen[@]} package(s) installed from Pages + Releases)"
