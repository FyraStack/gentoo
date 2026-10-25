# gentoo-cloud-images

Minimal x86_64 Gentoo cloud images for Proxmox with cloud-init support, in systemd and OpenRC.

The images are built from Gentoo's official stage3 tarballs, using Gentoo's binary package host wherever possible so builds take minutes instead of hours.

## Image defaults

|                  | systemd                                     | OpenRC                                    |
| ---------------- | ------------------------------------------- | ----------------------------------------- |
| Profile          | `default/linux/amd64/23.0/systemd`          | `default/linux/amd64/23.0`                |
| Stage3           | `stage3-amd64-systemd`                      | `stage3-amd64-openrc`                     |
| Network renderer | `systemd-networkd`, `systemd-resolved`      | NetworkManager                            |
| Logging          | journald                                    | sysklogd                                  |

Both images share the rest:

- Architecture: `x86_64`
- Firmware: UEFI/OVMF. GRUB is installed to the removable media path, so no NVRAM boot entry is needed
- Disk format: QCOW2 by default; release builds use compressed QCOW2
- Hypervisor target: Proxmox/QEMU/KVM
- Kernel: `sys-kernel/gentoo-kernel-bin` with a generic `dracut` initramfs. `installkernel` updates GRUB whenever the kernel is updated
- Cloud-init datasource: `NoCloud` and `ConfigDrive`, covering Proxmox Linux cloud-init seed formats
- Guest agent: QEMU guest agent enabled
- Root filesystem: ext4, grown to fill the disk on boot by cloud-init
- SSH: OpenSSH enabled, password authentication enabled, and root SSH login permitted by image default. The image is root-only by default; Proxmox/cloud-init can set root passwords/keys with normal portable cloud-init data
- `sudo`: members of `wheel` can use `sudo` without a password
- Interface names: `net.ifnames=0`, so the first interface is `eth0`
- Portage: `getbinpkg` and `binpkg-request-signature` are enabled, so `emerge` uses Gentoo's binary package host when a package matches your USE flags
- Firewall: none

The images also include `curl`, `nano`, `vim`, and `gentoolkit`.

The Gentoo repository isn't included in the image, since it's large and goes stale quickly. Run `emerge --sync` before installing anything.

### Why NetworkManager on OpenRC?

cloud-init's Gentoo support doesn't include a renderer for netifrc, so cloud-init can't write `/etc/conf.d/net`. NetworkManager runs fine under OpenRC and has a cloud-init renderer, so the OpenRC image uses it. It's built with minimal USE flags (no Wi-Fi, ModemManager, or PPP), and `no-auto-default=*` keeps it from adding its own connections on top of cloud-init's.

## Build

Builds need root, since they use loop devices, mounts, and `chroot`. You'll also need `curl`, `jq`, `sgdisk` (`gdisk`), `mkfs.vfat` (`dosfstools`), `mkfs.ext4`, and `qemu-img`.

```bash
sudo ./scripts/build.sh systemd
sudo ./scripts/build.sh openrc
```

For a smaller release artifact, build a compressed QCOW2:

```bash
sudo ./scripts/build.sh systemd --compress
```

The resulting image is written to `out/`, with a filename similar to:

```text
gentoo-systemd-cloud-proxmox-20261018T124555Z-x86_64.qcow2
```

Downloads are cached in `cache/`, so rebuilding with the same pins doesn't download anything again. You can build both flavors at the same time.

### Test

`scripts/smoke-test.sh` boots an image in QEMU with a NoCloud seed shaped like a real Fyra Stack VPS's, and checks that cloud-init configured the hostname and `eth0`, the root filesystem grew, DNS works, and `sshd` is listening. It doesn't need root, but it's very slow without KVM.

```bash
./scripts/smoke-test.sh out/gentoo-systemd-cloud-proxmox-*.qcow2
```

## Pinned sources

`sources.json` pins the stage3 tarball for each flavor (by path and SHA-256) and the commit of the Gentoo repository ([gentoo-mirror/gentoo](https://github.com/gentoo-mirror/gentoo), which includes the metadata cache) used for the build. It plays the same role as `flake.lock` in our NixOS image: builds only use what's pinned there.

`gentoo_repository` is the Gentoo ebuild repository (the `::gentoo` tree that Portage installs packages from), not this repository. It's pinned the same way `flake.lock` pins nixpkgs.

To move the pins forward:

```bash
./scripts/update-sources.sh
```

The script verifies each stage3 checksum against Gentoo's release engineering signing key before writing it. The `update.yaml` workflow runs it every Sunday and opens a pull request.

Gentoo only keeps recent stage3 builds on its mirrors, so builds from old pins will eventually stop working. Update the pins before building an old tag again.

## CI

| Workflow                | Runs on                  | Does                                                                     |
| ----------------------- | ------------------------ | ------------------------------------------------------------------------ |
| `check.yaml`            | Pushes and PRs to `main` | Lints the scripts, then builds and smoke tests both images               |
| `publish.yaml`          | `v*` tags, manual runs   | Builds and tests both images, and creates a draft release on tags        |
| `push-to-proxmox.yaml`  | Publishing a release     | Imports both images into Proxmox as `gentoo-<init>-<tag>.qcow2`          |
| `update.yaml`           | Weekly, manual runs      | Updates `sources.json` and opens a pull request                          |

`push-to-proxmox.yaml` uses the same variables and secrets as the NixOS repository: `PROXMOX_API_URL`, `PROXMOX_NODE`, `PROXMOX_IMPORT_STORAGE`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`, `TS_OAUTH_CLIENT_ID`, and `TS_OAUTH_SECRET`.

## Layout

- `scripts/build.sh`: creates the disk, unpacks the stage3 and repository, and runs the chroot setup
- `scripts/chroot-setup.sh`: runs inside the image to install packages, GRUB, and the kernel, and enable services
- `scripts/smoke-test.sh`: boots an image and checks it
- `scripts/update-sources.sh`: updates `sources.json`
- `rootfs/common`, `rootfs/systemd`, `rootfs/openrc`: files copied into the image before setup runs

## Notes

- This repository currently targets Proxmox only, like the NixOS image.
- The images use the standard (multilib) profiles instead of `no-multilib`, because Gentoo's binary package host builds for them.
- `COMMON_FLAGS` stays at the stage3 default (`-O2 -pipe`). Avoid `-march=native` if VMs can be migrated between hosts with different CPUs.

## License

[Apache License 2.0](LICENSE)
