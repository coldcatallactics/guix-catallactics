#!/usr/bin/env bash
# init-channel-auth.sh --- create the channel's OpenPGP signing identity.
#
# Run this ONCE, before the first commit.  It:
#   1. generates a dedicated ed25519 signing key (GPG asks for a passphrase);
#   2. writes .guix-authorizations with its fingerprint;
#   3. exports the public key to .git/channel-keyring/<FINGERPRINT>.key;
#   4. prints the signed-commit and orphan-keyring commands.
#
# The private key stays in your GnuPG home.  Never commit it.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -e .guix-authorizations ]; then
    echo "error: .guix-authorizations already exists; refusing to overwrite" >&2
    exit 1
fi

command -v gpg >/dev/null || { echo "error: gpg is required" >&2; exit 1; }

if [ "$#" -ge 2 ]; then
    name=$1
    email=$2
else
    read -r -p "Channel key name: " name
    read -r -p "Channel key email: " email
fi

[ -n "$name" ] && [ -n "$email" ] || {
    echo "error: name and email are required" >&2; exit 1; }

echo "==> generating channel signing key for $name <$email>"
gpg --quick-generate-key "$name <$email>" ed25519 sign 2y

fpr=$(gpg --list-keys --with-colons "$email" \
      | awk -F: '$1 == "fpr" { print $10; exit }')
[ -n "$fpr" ] || { echo "error: could not determine fingerprint" >&2; exit 1; }

echo "==> fingerprint: $fpr"
echo "$fpr" > .git/channel-fingerprint
# Make bare `git commit -S' use the channel key, not the user's default.
git config --local user.signingkey "$fpr"

cat > .guix-authorizations <<EOF
(authorizations
 (version 0)

 (("$fpr"
   (name "$name"))))
EOF

mkdir -p .git/channel-keyring
gpg --armor --export "$fpr" > ".git/channel-keyring/$fpr.key"

cat <<EOF

==> wrote .guix-authorizations and .git/channel-keyring/$fpr.key

Next steps:

  1. Commit the introduction (signed):

       git add .guix-authorizations
       git commit -S -m "channel: add authenticated introduction"

     Record the resulting commit hash as INTRO_COMMIT in README.org.

  2. Create the orphan keyring branch:

       git switch --orphan keyring
       cp .git/channel-keyring/$fpr.key .
       git add "$fpr.key"
       git commit -S -m "keyring: add channel signing key"
       git push -u origin keyring
       git switch main

  3. Sign every later commit:

       git commit -S

     Verify with:

       guix git authenticate <INTRO_COMMIT> "$fpr"

Do not use the GitHub web editor or web merge on main.
EOF
