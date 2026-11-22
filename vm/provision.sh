#!/usr/bin/env bash
# Runs once as root at first boot (called from cloud-init runcmd).
# Installs tools that are not in Debian: OpenTofu and tflint (checksum verified).
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/ailab/versions.env   # TOFU_VERSION, TFLINT_VERSION (may be empty = latest)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

latest() {  # latest <github owner/repo> -> version without leading v
  curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/v##'
}

# --- OpenTofu (.deb from official release, sha256 checked) -------------------
v="${TOFU_VERSION:-$(latest opentofu/opentofu)}"
base="https://github.com/opentofu/opentofu/releases/download/v${v}"
curl -fsSLO "$base/tofu_${v}_amd64.deb"
curl -fsSLO "$base/tofu_${v}_SHA256SUMS"
grep " tofu_${v}_amd64.deb\$" "tofu_${v}_SHA256SUMS" | sha256sum -c -
apt-get install -y --no-install-recommends "./tofu_${v}_amd64.deb"

# --- tflint (zip from official release, sha256 checked) ----------------------
v="${TFLINT_VERSION:-$(latest terraform-linters/tflint)}"
base="https://github.com/terraform-linters/tflint/releases/download/v${v}"
curl -fsSLO "$base/tflint_linux_amd64.zip"
curl -fsSLO "$base/checksums.txt"
grep " tflint_linux_amd64.zip\$" checksums.txt | sha256sum -c -
unzip -q tflint_linux_amd64.zip tflint
install -m 0755 tflint /usr/local/bin/tflint

tofu version | head -1
tflint --version | head -1
