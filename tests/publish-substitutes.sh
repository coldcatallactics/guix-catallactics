#!/usr/bin/env bash
# Build a hybrid Guix substitute mirror:
#
#   * GitHub Pages (gh-pages branch) carries the small metadata:
#     nix-cache-info, one <hash>.narinfo per store item, and pubkey.
#   * GitHub Releases carries the nar archives, because Pages rejects files
#     over 100 MB and every package in this channel is larger than that.
#
# Guix asks for a narinfo at <substitute-url>/<hash>.narinfo, then fetches the
# absolute URL named in its `URL:' field.  That is why the narinfos can stay on
# Pages while the nars live in a release: only the URL line changes.  The URL,
# Compression and FileSize fields are outside the signed normative part of a
# narinfo (see the comment in guix/scripts/publish.scm), so the existing
# signature remains valid after the rewrite.
#
# This script bakes and rewrites locally.  Uploading .substitute-nars to the
# GitHub release is the workflow's job; tests/check-substitutes.sh proves the
# resulting Pages + Releases pair works from a clean machine.
#
# Inputs (environment):
#   GUIX_SIGNING_KEY   private signing key, canonical sexp text.  Required.
#   GUIX_BUILT_PATHS   file of store paths built by tests/build-all.sh.  Required.
#   NAR_BASE_URL       public base URL of the release assets, e.g.
#                      https://github.com/USER/REPO/releases/download/TAG.
#                      Required.  A fake value plus ALLOW_NO_UPLOAD=1 is fine
#                      for a local dry run.
#   GUIX_SUBST_CACHE   bake directory (default ./.substitute-cache)
#   SITE_DIR           Pages payload (default ./.substitute-site)
#   NARS_DIR           nar staging directory (default ./.substitute-nars)
#   GUIX_PUBLISH_PORT  local port for the baker (default 8000)
#   ALLOW_NO_UPLOAD=1  local dry run: accept a fake NAR_BASE_URL and say that
#                      no upload is performed here (the workflow still uploads).
#
# The matching public key is .guix-substitutes.pub in the repository; it is
# copied into the Pages payload as `pubkey' for users to authorize.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "publish-substitutes: $*" >&2; exit 1; }

: "${GUIX_SIGNING_KEY:?GUIX_SIGNING_KEY (the private signing key) is required}"
: "${GUIX_BUILT_PATHS:?GUIX_BUILT_PATHS (built store paths) is required}"
: "${NAR_BASE_URL:?NAR_BASE_URL (public release asset base) is required}"
NAR_BASE_URL=${NAR_BASE_URL%/}
case "$NAR_BASE_URL" in
  http://*|https://*) ;;
  *) fail "NAR_BASE_URL must be an absolute http(s) URL, got: $NAR_BASE_URL" ;;
esac

[ -s "$GUIX_BUILT_PATHS" ] || fail "no built paths to publish"
[ -f .guix-substitutes.pub ] || fail ".guix-substitutes.pub is missing"
grep -q '(private-key' <<<"$GUIX_SIGNING_KEY" ||
  fail "GUIX_SIGNING_KEY does not look like a Guix private key (expected a (private-key ...) sexp)"

CACHE="${GUIX_SUBST_CACHE:-$PWD/.substitute-cache}"
SITE="${SITE_DIR:-$PWD/.substitute-site}"
NARS="${NARS_DIR:-$PWD/.substitute-nars}"
PORT="${GUIX_PUBLISH_PORT:-8000}"

rm -rf "$CACHE" "$SITE" "$NARS"
mkdir -p "$CACHE" "$SITE" "$NARS"

# Never let guix publish fall back to /etc/guix/signing-key.sec: the key is
# supplied explicitly and the temporary copy is removed on exit.
key_dir=$(mktemp -d)
printf '%s\n' "$GUIX_SIGNING_KEY" > "$key_dir/signing-key.sec"
chmod 600 "$key_dir/signing-key.sec"
cp .guix-substitutes.pub "$key_dir/signing-key.pub"

publish_pid=""
cleanup() {
  if [ -n "$publish_pid" ]; then kill "$publish_pid" 2>/dev/null || true; fi
  rm -rf "$key_dir"
}
trap cleanup EXIT

echo "==> starting guix publish on 127.0.0.1:$PORT"
guix publish --cache="$CACHE" \
             --private-key="$key_dir/signing-key.sec" \
             --public-key="$key_dir/signing-key.pub" \
             -C gzip --nar-path=nar \
             --listen=127.0.0.1 --port="$PORT" \
             --workers="$(nproc)" --cache-bypass-threshold=1G \
             >"$key_dir/publish.log" 2>&1 &
publish_pid=$!

up=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/nix-cache-info" >/dev/null; then
    up=1
    break
  fi
  sleep 1
done
[ "$up" = 1 ] || {
  cat "$key_dir/publish.log" >&2
  fail "guix publish did not start"
}

paths=$(sort -u "$GUIX_BUILT_PATHS")
[ -n "$paths" ] || fail "GUIX_BUILT_PATHS is empty"
want=$(printf '%s\n' "$paths" | wc -l)
echo "==> baking narinfos and nars for $want store items"

# Fire all narinfo requests first so the baker's worker pool works in
# parallel; waiting after each request would serialize the whole bake.
for path in $paths; do
  [ -e "$path" ] || fail "store path does not exist: $path"
  base=$(basename "$path")
  curl -sf "http://127.0.0.1:$PORT/${base%%-*}.narinfo" >/dev/null 2>&1 || true
done

# A completed bake writes the nar first and the narinfo last, so the narinfo
# is the done marker.  The generous timeout covers multi-hundred-MB nars on a
# slow CI disk.
for _ in $(seq 1 1800); do
  have=$(find "$CACHE" -name '*.narinfo' 2>/dev/null | wc -l)
  [ "$have" -ge "$want" ] && break
  sleep 2
done
have=$(find "$CACHE" -name '*.narinfo' 2>/dev/null | wc -l)
echo "==> baked $have/$want narinfos"
[ "$have" -ge "$want" ] || {
  echo "==> cache contents:" >&2
  find "$CACHE" -maxdepth 3 -type f -printf '%p\n' >&2 2>/dev/null || true
  fail "not every store item was baked"
}

kill "$publish_pid" 2>/dev/null || true
wait "$publish_pid" 2>/dev/null || true
publish_pid=""

# Rearrange the cache into the client-facing pair of directories.
# `guix publish' may put the files at CACHE/<base>.narinfo or
# CACHE/gzip/<base>.narinfo depending on the version; find them instead of
# assuming one layout.
count=0
for path in $paths; do
  base=$(basename "$path")
  hash=${base%%-*}
  narinfo=$(find "$CACHE" -name "$base.narinfo" -type f -print -quit)
  nar=$(find "$CACHE" -name "$base.nar" -type f -print -quit)
  [ -n "$narinfo" ] || fail "missing narinfo for $base"
  [ -n "$nar" ] || fail "missing nar for $base"

  # The signature covers the narinfo's normative fields, not URL/Compression/
  # FileSize.  Replace exactly the URL line with the absolute release location.
  if ! awk -v url="$NAR_BASE_URL/$base.nar" '
      /^URL:/ { print "URL: " url; seen=1; next }
      { print }
      END { exit(seen ? 0 : 1) }
    ' "$narinfo" > "$SITE/$hash.narinfo"; then
    fail "narinfo has no URL field: $narinfo"
  fi

  cp "$nar" "$NARS/$base.nar"
  size=$(stat -c %s "$NARS/$base.nar" 2>/dev/null || wc -c <"$NARS/$base.nar")
  printf '    %-70s %s MiB\n' "$base" "$((size / 1024 / 1024))"
  count=$((count + 1))
done

# Pages payload: metadata only.  The nars are deliberately NOT here.
cp .guix-substitutes.pub "$SITE/pubkey"
printf 'StoreDir=/gnu/store\nWantMassQuery=1\nPriority=10\n' > "$SITE/nix-cache-info"
: > "$SITE/.nojekyll"

site_size=$(du -sb "$SITE" | cut -f1)
nar_size=$(du -sb "$NARS" | cut -f1)
echo "==> Pages payload: $SITE ($count narinfos, $((site_size / 1024)) KiB)"
echo "==> nar staging:   $NARS ($count nars, $((nar_size / 1024 / 1024)) MiB)"
echo "==> nar URL base:  $NAR_BASE_URL"
if [ "${ALLOW_NO_UPLOAD:-0}" = 1 ]; then
  echo "==> ALLOW_NO_UPLOAD=1: no upload is performed by this script"
else
  echo "==> next: upload $NARS to the GitHub release (the workflow does this)"
fi
