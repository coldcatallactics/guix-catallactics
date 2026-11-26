# Repository rules

This is `guix-catallactics`, a personal public GNU Guix channel.

- Channel name: `catallactics`; modules live under `catallactics/` with names
  like `(catallactics autolith)`.
- Module root: `.guix-channel` must keep `(directory "/")` because the module
  names are `(catallactics …)`. Pointing it at `catallactics/` makes
  `guix pull` look for `(autolith …)`, `(opencode …)`, etc. and breaks the
  channel. `tests/check-static.sh` enforces the path/name match; do not
  "tidy" the directory field.
- `.guix-channel` declares Nonguix as a dependency. Do not add a second
  channel entry for Nonguix in user instructions.
- Packages: `autolith-bin`, `learnharness-bin`, `xenolith`, `opencode-bin`.
  `autolith-bridge` is documented but not packaged: Guix's Swift toolchain is
  incomplete. Post-v1 packages go in new modules, one per upstream project.
- Honest naming: vendor binaries use the `-bin` suffix. Do not label a vendor
  binary as a source package.
- No fleet-specific material: no `/run/secrets`, no fleet module imports, no
  machine-specific paths, no NVIDIA-only mesa pairing.
- Every commit on `main` is signed and authenticated by
  `.guix-authorizations`. Do not use the GitHub web editor or web merge on
  `main`. Do not rewrite published history.
- Distinguish the two keys: the OpenPGP key authenticates commits; the Guix
  Ed25519 key signs substitute narinfos. Never commit private key material.
- CI pins Guix and Nonguix in `tests/channels-lock`. Update it
  deliberately with `tests/update-channels-lock.sh`, never by hand-editing
  prose.
- Tests and CI mirror the public packages; a new package needs a module, a
  smoke test under `tests/smoke/`, and a `news.txt` entry after it lands.
- CI publishes small metadata to GitHub Pages and the nar archives to a
  unique GitHub Release (they exceed Pages' 100 MB file limit); see
  `docs/mirror.org`.
- The channel is personal and curated. Do not turn it into a dumping ground.
