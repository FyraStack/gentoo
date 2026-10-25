#!/usr/bin/env bash
# Pin the latest stage3 tarballs and Gentoo repository commit in sources.json.
#
# This is the equivalent of `nix flake update` for this repository: builds only
# ever use what's pinned in sources.json, and this script is the only thing that
# moves the pins forward. Stage3 checksums are verified against Gentoo's release
# signing key before they're written.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sources="${repo_root}/sources.json"

autobuilds="https://distfiles.gentoo.org/releases/amd64/autobuilds"
service_keys="https://qa-reports.gentoo.org/output/service-keys.gpg"
# Gentoo Linux Release Engineering (Automated Weekly Release Key) <releng@gentoo.org>
releng_key="13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
mirror_repo="gentoo-mirror/gentoo"
mirror_branch="stable"

for cmd in curl gpg jq; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required" >&2; exit 1; }
done

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

curl -fsSL "$service_keys" | gpg --quiet --import 2>/dev/null

# Print the signed body of a clearsigned file, but only if it's signed by the
# release engineering key. --status-fd reports the primary key fingerprint.
verify_clearsigned() {
  local file=$1 status
  status=$(gpg --status-fd 1 --verify "$file" 2>/dev/null) || {
    echo "Error: bad signature on $file" >&2
    return 1
  }
  if ! grep -Eq "^\[GNUPG:\] VALIDSIG .* ${releng_key}\$" <<<"$status"; then
    echo "Error: $file is not signed by the Gentoo release engineering key" >&2
    return 1
  fi
  gpg --quiet --decrypt "$file" 2>/dev/null
}

workdir=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME" "$workdir"' EXIT

stage3_json='{}'
for init in systemd openrc; do
  flavor="stage3-amd64-${init}"

  curl -fsSL "${autobuilds}/latest-${flavor}.txt" -o "${workdir}/latest-${init}.txt"
  path=$(verify_clearsigned "${workdir}/latest-${init}.txt" \
    | awk -v f="$flavor" '!/^#/ && $1 ~ f { print $1; exit }')
  [[ -n "$path" ]] || { echo "Error: couldn't find the latest ${flavor}" >&2; exit 1; }

  curl -fsSL "${autobuilds}/${path}.sha256" -o "${workdir}/${init}.sha256"
  sha256=$(verify_clearsigned "${workdir}/${init}.sha256" \
    | awk -v f="${path##*/}" '$2 == f { print $1; exit }')
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Error: couldn't read the checksum for ${path}" >&2; exit 1; }

  echo "${init}: ${path}"
  stage3_json=$(jq --arg init "$init" --arg path "$path" --arg sha256 "$sha256" \
    '.[$init] = { path: $path, sha256: $sha256 }' <<<"$stage3_json")
done

# gentoo-mirror/gentoo includes the metadata cache, so emerge doesn't have to
# regenerate it during the build. Its commits are signed by repomirrorci@gentoo.org.
commit=$(curl -fsSL "https://api.github.com/repos/${mirror_repo}/commits/${mirror_branch}" \
  | jq -r '.sha')
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "Error: couldn't resolve ${mirror_repo}@${mirror_branch}" >&2; exit 1; }
echo "gentoo repository: ${commit}"

jq -n \
  --argjson stage3 "$stage3_json" \
  --arg repo "$mirror_repo" \
  --arg commit "$commit" \
  '{
    stage3: $stage3,
    gentoo_repository: { github: $repo, commit: $commit }
  }' >"${sources}.tmp"
mv "${sources}.tmp" "$sources"
