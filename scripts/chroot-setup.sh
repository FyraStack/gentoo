#!/bin/bash
# Runs inside the image's chroot. Called by scripts/build.sh, don't run it directly.
#
# Expects INIT (systemd or openrc), ROOT_UUID, EFI_UUID, and JOBS in the environment.

set -eo pipefail
# shellcheck disable=SC1091
source /etc/profile
set -u

: "${INIT:?}" "${ROOT_UUID:?}" "${EFI_UUID:?}" "${JOBS:?}"

emerge_opts=(
  --getbinpkg
  # Save anything compiled here to the binary package cache, so the next build
  # can reuse it
  --buildpkg
  --binpkg-respect-use=y
  --jobs="$JOBS"
  --load-average="$JOBS"
  --quiet-build=y
  --verbose
)
export MAKEOPTS="-j${JOBS}"
# News is for the people using the image, so don't mark it as read here.
#
# Packages built here and cached between builds aren't signed, so don't require
# signatures on every binary package during the build. Packages from Gentoo's
# binary package host are still verified, because binrepos.conf sets
# verify-signature = true. The image itself keeps binpkg-request-signature on.
export FEATURES="-news -binpkg-request-signature"
if grep -rqsiE '^\s*verify-signature\s*=\s*false' /etc/portage/binrepos.conf /usr/share/portage/config/binrepos.conf; then
  echo "Error: a binary package host has signature verification turned off" >&2
  exit 1
fi

echo ">>> Configuring Portage"
cat >>/etc/portage/make.conf <<'EOF'

# Added by the Fyra Stack image build. Install packages from Gentoo's binary
# package host when one matches your USE flags, and check its signatures.
FEATURES="${FEATURES} getbinpkg binpkg-request-signature"
EOF

echo ">>> Configuring locale and time zone"
cat >/etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
C.UTF-8 UTF-8
EOF
locale-gen --quiet
eselect locale set en_US.utf8 >/dev/null
ln -sf ../usr/share/zoneinfo/UTC /etc/localtime
[[ "$INIT" == openrc ]] && echo UTC >/etc/timezone

cat >/etc/fstab <<EOF
# <fs>                                     <mountpoint> <type> <opts>            <dump> <pass>
UUID=${ROOT_UUID}  /            ext4   defaults,noatime  0      1
UUID=${EFI_UUID}                             /efi         vfat   umask=0077        0      2
EOF

echo ">>> Updating @world"
emerge "${emerge_opts[@]}" --update --deep --newuse @world

echo ">>> Installing GRUB"
emerge "${emerge_opts[@]}" --noreplace sys-boot/grub
cat >>/etc/default/grub <<'EOF'

# Added by the Fyra Stack image build. Show the boot menu and kernel output on
# both the Proxmox console and the serial port.
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX="console=tty1 console=ttyS0,115200n8 net.ifnames=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
EOF
# --removable installs to the fallback path (EFI/BOOT/BOOTX64.EFI), so the image
# boots without any NVRAM boot entries
grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram

echo ">>> Installing packages"
packages=(
  app-admin/sudo
  app-editors/nano
  app-editors/vim
  app-emulation/cloud-init
  app-emulation/qemu-guest-agent
  app-portage/gentoolkit
  net-misc/curl
  sys-fs/growpart
  sys-kernel/gentoo-kernel-bin
)
if [[ "$INIT" == openrc ]]; then
  packages+=(
    app-admin/sysklogd
    net-misc/networkmanager
  )
fi
# --select adds them to @world, so --depclean keeps them
emerge "${emerge_opts[@]}" --noreplace --select "${packages[@]}"

# installkernel already runs this, but make sure the config matches our settings
grub-mkconfig -o /boot/grub/grub.cfg

emerge "${emerge_opts[@]}" --depclean

# Drop cached binary packages that aren't installed anymore, so the cache only
# holds what the next build is likely to use
eclean-pkg --deep --quiet

echo ">>> Enabling services"
if [[ "$INIT" == systemd ]]; then
  systemctl enable \
    sshd.service \
    systemd-networkd.service \
    systemd-resolved.service \
    systemd-timesyncd.service \
    qemu-guest-agent.service
  # cloud-init's unit names change between releases, so enable whatever it ships
  for unit in /usr/lib/systemd/system/cloud-*.service; do
    systemctl enable "${unit##*/}"
  done
  systemctl enable cloud-init.target 2>/dev/null || true
else
  rc-update add cloud-init-local boot
  # Start logging early, since cloud-init logs to syslog
  rc-update add sysklogd boot
  for service in cloud-init cloud-config cloud-final sshd NetworkManager qemu-guest-agent; do
    rc-update add "$service" default
  done
fi

echo ">>> Cleaning up"
# getuto starts gpg-agent for the binary package keyring. Stop it so nothing
# is left running in the chroot.
GNUPGHOME=/etc/portage/gnupg gpgconf --kill all 2>/dev/null || true
passwd --lock root >/dev/null
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs >/dev/null 2>&1 || true
rm -rf /var/lib/cloud/*
if [[ "$INIT" == systemd ]]; then
  # An empty machine-id makes systemd treat the next boot as the first one
  : >/etc/machine-id
  rm -f /var/lib/dbus/machine-id
fi
find /var/log -type f -delete
rm -f /root/.bash_history
