#!/usr/bin/env bash
# Build a Gentoo cloud image for Proxmox from the stage3 pinned in sources.json.
#
# Usage: sudo scripts/build.sh <systemd|openrc> [--compress] [--size SIZE] [--output DIR]
#
# Needs root for loop devices, mounts, and chroot. Downloads are cached in
# ./cache, so rebuilding with the same pins doesn't fetch anything again.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
autobuilds="https://distfiles.gentoo.org/releases/amd64/autobuilds"

usage() {
  echo "Usage: $0 <systemd|openrc> [--compress] [--size SIZE] [--output DIR]" >&2
  exit 1
}

args=("$@")
init=${1:-}
[[ "$init" == systemd || "$init" == openrc ]] || usage
shift

compress=false
# Small enough to keep the base image light. Proxmox grows the disk and
# cloud-init grows the root filesystem on first boot.
size=5G
output="${repo_root}/out"
while [[ $# -gt 0 ]]; do
  case $1 in
    --compress) compress=true ;;
    --size) size=${2:?}; shift ;;
    --output) output=${2:?}; shift ;;
    *) usage ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "Error: run this as root" >&2; exit 1; }
for cmd in blkid chroot curl jq losetup mkfs.ext4 mkfs.vfat qemu-img sgdisk sha256sum tar unshare xz; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required" >&2; exit 1; }
done

# Run in a private mount namespace. Otherwise our mounts propagate into the
# namespaces of sandboxed host services (like systemd-udevd), which keeps the
# filesystem mounted there after we unmount it, and leaves it unclean.
if [[ -z "${GENTOO_IMAGE_BUILD_NS:-}" ]]; then
  export GENTOO_IMAGE_BUILD_NS=1
  exec unshare --mount --propagation private -- "$0" "${args[@]}"
fi

stage3_path=$(jq -r --arg init "$init" '.stage3[$init].path' "${repo_root}/sources.json")
stage3_sha256=$(jq -r --arg init "$init" '.stage3[$init].sha256' "${repo_root}/sources.json")
repo_github=$(jq -r '.gentoo_repository.github' "${repo_root}/sources.json")
repo_commit=$(jq -r '.gentoo_repository.commit' "${repo_root}/sources.json")
stage3_stamp=${stage3_path%%/*}

cache="${repo_root}/cache"
work="${repo_root}/work/${init}"
root="${work}/root"
raw="${work}/disk.raw"
mkdir -p "$cache/distfiles" "$output"

# ---------------------------------------------------------------------------
# Downloads

fetch() {
  local url=$1 dest=$2
  [[ -f "$dest" ]] && return
  echo ">>> Downloading ${url}"
  local part
  # Unique temporary name, so parallel builds sharing the cache don't collide
  part=$(mktemp "${dest}.XXXXXX.part")
  curl -fL --retry 5 --retry-all-errors -o "$part" "$url"
  mv "$part" "$dest"
}

stage3="${cache}/${stage3_path##*/}"
fetch "${autobuilds}/${stage3_path}" "$stage3"
if ! sha256sum --check --status <<<"${stage3_sha256}  ${stage3}"; then
  echo "Error: checksum mismatch for ${stage3}" >&2
  rm -f "$stage3"
  exit 1
fi

repo_tarball="${cache}/gentoo-${repo_commit}.tar.gz"
fetch "https://github.com/${repo_github}/archive/${repo_commit}.tar.gz" "$repo_tarball"

# ---------------------------------------------------------------------------
# Disk

loopdev=""
cleanup() {
  if [[ -d "$root" ]]; then
    umount --recursive "$root" 2>/dev/null || true
  fi
  if [[ -n "$loopdev" ]]; then
    losetup --detach "$loopdev" || true
  fi
}
trap cleanup EXIT

cleanup
rm -rf "$work"
mkdir -p "$root"

echo ">>> Creating ${size} disk"
truncate --size "$size" "$raw"
# UEFI only, like our NixOS image. The root partition comes last so cloud-init
# can grow it into the rest of the disk.
sgdisk --clear \
  --new 1:0:+256M --typecode 1:ef00 --change-name 1:EFI \
  --new 2:0:0 --typecode 2:8304 --change-name 2:root \
  "$raw" >/dev/null

loopdev=$(losetup --find --show --partscan "$raw")
udevadm settle 2>/dev/null || true
efi_part="${loopdev}p1"
root_part="${loopdev}p2"

mkfs.vfat -F 32 -n EFI "$efi_part" >/dev/null
# Skip newer ext4 features so older GRUB and e2fsprogs versions can still read it.
mkfs.ext4 -q -L root -m 1 -O ^orphan_file,^metadata_csum_seed "$root_part" 2>/dev/null \
  || mkfs.ext4 -q -L root -m 1 "$root_part"

mount "$root_part" "$root"
mkdir -p "${root}/efi"
mount "$efi_part" "${root}/efi"

# ---------------------------------------------------------------------------
# Root filesystem

echo ">>> Unpacking ${stage3##*/}"
tar xpf "$stage3" --xattrs-include='*.*' --numeric-owner -C "$root"

echo ">>> Unpacking Gentoo repository at ${repo_commit}"
mkdir -p "${root}/var/db/repos/gentoo"
tar xzf "$repo_tarball" --strip-components=1 --no-same-owner -C "${root}/var/db/repos/gentoo"
chown -R 250:250 "${root}/var/db/repos/gentoo" # portage:portage in the stage3

echo ">>> Copying image files"
for layer in common "$init"; do
  tar -C "${repo_root}/rootfs/${layer}" --owner=0 --group=0 -cf - . | tar -C "$root" -xf - --no-overwrite-dir
done
chmod 0440 "${root}/etc/sudoers.d/90-wheel"

install -m 0755 "${repo_root}/scripts/chroot-setup.sh" "${root}/root/chroot-setup.sh"

# Keep downloads and build files out of the image
mkdir -p "${work}/binpkgs" "${work}/tmp" "${root}/var/cache/binpkgs" "${root}/var/cache/distfiles" "${root}/var/tmp/portage"
mount --bind "${work}/binpkgs" "${root}/var/cache/binpkgs"
mount --bind "${cache}/distfiles" "${root}/var/cache/distfiles"
mount --bind "${work}/tmp" "${root}/var/tmp/portage"

mount --types proc /proc "${root}/proc"
mount --rbind /sys "${root}/sys" && mount --make-rslave "${root}/sys"
mount --rbind /dev "${root}/dev" && mount --make-rslave "${root}/dev"
# A private /run, so gpg-agent sockets from parallel builds don't collide
mount --types tmpfs --options mode=0755,nosuid,nodev tmpfs "${root}/run"
cp --dereference /etc/resolv.conf "${root}/etc/resolv.conf"

echo ">>> Running setup in chroot"
chroot "$root" /usr/bin/env -i \
  HOME=/root TERM="${TERM:-dumb}" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  INIT="$init" \
  ROOT_UUID="$(blkid -s UUID -o value "$root_part")" \
  EFI_UUID="$(blkid -s UUID -o value "$efi_part")" \
  JOBS="$(nproc)" \
  /bin/bash /root/chroot-setup.sh

rm -f "${root}/root/chroot-setup.sh"

# The repository is large and goes stale quickly, so leave it out of the image.
# Users run `emerge --sync` first, as our docs describe.
find "${root}/var/db/repos/gentoo" -mindepth 1 -delete

# cloud-init and the network stack own DNS from here on
rm -f "${root}/etc/resolv.conf"
if [[ "$init" == systemd ]]; then
  ln -s ../run/systemd/resolve/stub-resolv.conf "${root}/etc/resolv.conf"
else
  touch "${root}/etc/resolv.conf"
fi

echo ">>> Unmounting"
# Discard freed blocks so deleted files don't end up in the qcow2
fstrim "${root}/efi" || true
fstrim "$root" || true
umount --recursive "$root"
# Fail here instead of shipping a broken filesystem. Exit codes 0 and 1 mean
# the filesystem is clean, or was fixed.
fsck_status=0
fsck.ext4 -fy "$root_part" >/dev/null || fsck_status=$?
if [[ $fsck_status -gt 1 ]]; then
  echo "Error: fsck.ext4 failed with exit code ${fsck_status}" >&2
  exit 1
fi
losetup --detach "$loopdev"
loopdev=""

# ---------------------------------------------------------------------------
# Convert

name="gentoo-${init}-cloud-proxmox-${stage3_stamp}-x86_64"
$compress && name+="-compressed"
echo ">>> Writing ${output}/${name}.qcow2"
convert_args=(-f raw -O qcow2)
$compress && convert_args+=(-c)
qemu-img convert "${convert_args[@]}" "$raw" "${output}/${name}.qcow2"
rm -f "$raw"

if [[ -n "${SUDO_UID:-}" ]]; then
  chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$output" "${output}/${name}.qcow2"
fi
ls -lh "${output}/${name}.qcow2"
