#!/usr/bin/env bash
# Boot an image in QEMU with a NoCloud seed and check that it comes up the way a
# Fyra Stack VPS would: cloud-init runs, the network config is applied, the
# root filesystem grows, DNS works, and sshd is listening.
#
# Usage: scripts/smoke-test.sh IMAGE.qcow2
#
# Doesn't need root. Uses KVM when /dev/kvm is usable, and is very slow without it.

set -euo pipefail

image=${1:?Usage: $0 IMAGE.qcow2}
timeout_seconds=${SMOKE_TIMEOUT:-900}

for cmd in qemu-img qemu-system-x86_64; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required" >&2; exit 1; }
done

mkiso=""
for cmd in xorriso genisoimage mkisofs; do
  if command -v "$cmd" >/dev/null; then mkiso=$cmd; break; fi
done
[[ -n "$mkiso" ]] || { echo "Error: xorriso, genisoimage, or mkisofs is required" >&2; exit 1; }

ovmf_code=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/qemu/ovmf-x86_64-code.bin; do
  if [[ -f "$f" ]]; then ovmf_code=$f; break; fi
done
[[ -n "$ovmf_code" ]] || { echo "Error: couldn't find OVMF firmware" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Test on a throwaway overlay that's bigger than the image, like a resized Proxmox disk
qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$image")" "${work}/disk.qcow2" 10G

mac="52:54:00:12:34:56"
mkdir "${work}/seed"
cat >"${work}/seed/meta-data" <<'EOF'
instance-id: smoke-test
local-hostname: smoke-test
EOF
# Same shape as the network config our VPSes get, using QEMU's user networking
cat >"${work}/seed/network-config" <<EOF
network:
  version: 2
  ethernets:
    public0:
      match:
        macaddress: "${mac}"
      set-name: eth0
      dhcp4: false
      dhcp6: false
      addresses:
        - 10.0.2.15/24
      routes:
        - to: 0.0.0.0/0
          via: 10.0.2.2
          on-link: true
      nameservers:
        addresses:
          - 10.0.2.3
EOF
# The checks run in the background so they can wait for services that start
# after cloud-init finishes, like sshd on OpenRC. They power the VM off when done.
cat >"${work}/seed/user-data" <<'EOF'
#cloud-config
chpasswd:
  expire: false
  users:
    - name: root
      password: smoke-test
      type: text
write_files:
  - path: /usr/local/bin/smoke-test
    permissions: "0755"
    content: |
      #!/bin/sh
      wait_for() {
        i=0
        while [ $i -lt 120 ]; do
          if sh -c "$1" >/dev/null 2>&1; then echo ok; return; fi
          i=$((i + 1))
          sleep 1
        done
        echo failed
      }
      # Collect results in a file first, then write them to the serial port in
      # one go. Closing the port waits for the output to drain, and the sleep is
      # extra margin, so nothing is lost when the VM powers off right after.
      {
      echo "SMOKE-INIT: $(cat /proc/1/comm)"
      echo "SMOKE-HOSTNAME: $(hostname)"
      echo "SMOKE-ADDR: $(ip -o -4 addr show dev eth0 | awk '{print $4}')"
      echo "SMOKE-ROOT-SIZE-GB: $(df -BG --output=size / | tail -1 | tr -dc 0-9)"
      echo "SMOKE-DNS: $(wait_for 'getent hosts distfiles.gentoo.org')"
      echo "SMOKE-SSHD: $(wait_for "ss -Hltn 'sport = :22' | grep -q .")"
      echo "SMOKE-QGA: $(wait_for 'pgrep -x qemu-ga')"
      echo "SMOKE-DONE"
      } >/run/smoke-test.log 2>&1
      cat /run/smoke-test.log >/dev/ttyS0
      sleep 5
      poweroff
runcmd:
  - [sh, -c, "nohup /usr/local/bin/smoke-test >/dev/null 2>&1 &"]
EOF
iso_args=(-quiet -o "${work}/seed.iso" -V cidata -J -r "${work}/seed")
if [[ "$mkiso" == xorriso ]]; then
  xorriso -as mkisofs "${iso_args[@]}"
else
  "$mkiso" "${iso_args[@]}"
fi

accel=(-accel tcg)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
fi

echo ">>> Booting ${image}"
set +e
timeout "$timeout_seconds" qemu-system-x86_64 \
  "${accel[@]}" \
  -machine q35 \
  -m 2048 \
  -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=virtio,format=qcow2,file="${work}/disk.qcow2" \
  -drive if=ide,media=cdrom,format=raw,file="${work}/seed.iso" \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0,mac="$mac" \
  -device virtio-serial \
  -chardev socket,id=qga0,path="${work}/qga.sock",server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -nographic \
  -serial file:"${work}/serial.log" \
  -monitor none
status=$?
set -e

tr -d '\r' <"${work}/serial.log" >"${work}/serial.txt"
cp "${work}/serial.txt" "${SMOKE_LOG:-smoke-test-serial.log}"

if [[ $status -eq 124 ]]; then
  echo "Error: the VM didn't power off within ${timeout_seconds} seconds" >&2
fi

result() { sed -n "s/^.*$1: //p" "${work}/serial.txt" | tail -1; }

failed=0
check() {
  local name=$1 actual=$2 expected=$3
  if [[ "$actual" == "$expected" ]]; then
    echo "ok: ${name} is ${actual}"
  else
    echo "FAIL: ${name} is '${actual}', expected '${expected}'" >&2
    failed=1
  fi
}

grep -q "SMOKE-DONE" "${work}/serial.txt" || { echo "FAIL: the smoke test didn't run" >&2; failed=1; }
case $(basename "$image") in
  *systemd*) check "init" "$(result SMOKE-INIT)" "systemd" ;;
  *openrc*) check "init" "$(result SMOKE-INIT)" "init" ;;
esac
check "hostname" "$(result SMOKE-HOSTNAME)" "smoke-test"
check "eth0 address" "$(result SMOKE-ADDR)" "10.0.2.15/24"
check "DNS" "$(result SMOKE-DNS)" "ok"
check "sshd" "$(result SMOKE-SSHD)" "ok"
check "QEMU guest agent" "$(result SMOKE-QGA)" "ok"
root_size=$(result SMOKE-ROOT-SIZE-GB)
if [[ "${root_size:-0}" -ge 9 ]]; then
  echo "ok: root filesystem grew to ${root_size}G"
else
  echo "FAIL: root filesystem is ${root_size:-unknown}G, expected it to grow to about 10G" >&2
  failed=1
fi

if [[ $failed -ne 0 ]]; then
  echo "Last 40 lines of the serial log:" >&2
  tail -n 40 "${work}/serial.txt" >&2
  echo "Serial log saved to ${SMOKE_LOG:-smoke-test-serial.log}" >&2
  exit 1
fi
echo "All checks passed"
