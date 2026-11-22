#!/usr/bin/env bash
# Run in the OPERATOR environment (not in the lab).
# Needs: gh (logged in, read access to the repo), tar, sha256sum.
# Downloads a release, verifies checksum + build provenance, unpacks it.
set -Eeuo pipefail

REPO="__REPO__"
TAG="${1:?usage: operator-fetch.sh <tag> [dest-dir]}"
DEST="${2:-./release-$TAG}"

mkdir -p "$DEST"
cd "$DEST"
gh release download "$TAG" --repo "$REPO" --clobber

sha256sum -c SHA256SUMS
for f in bundle-*.tar.gz; do
  gh attestation verify "$f" --repo "$REPO"
done

mkdir -p src
tar -xzf bundle-*.tar.gz -C src

cat <<EOF

Verified and unpacked to: $PWD/src
Review, then apply manually, e.g.:
  cd src/tofu    && tofu init && tofu plan -out=tfplan && tofu apply tfplan
  cd src/ansible && ansible-playbook -i <inventory> <playbook>.yml --check --diff
EOF
