#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== NexHash EdgeOS Secure Boot Repair ==="

if [[ $EUID -ne 0 ]]; then
  echo "Execute com sudo."
  exit 1
fi

# Find the internal non-USB disk containing the installed NexHash system.
DISK=""
while read -r name type tran size model; do
  [[ "$type" == "disk" ]] || continue
  [[ "$tran" == "usb" ]] && continue
  if [[ "$model" == *"Samsung SSD 860"* || "$size" -gt 100000000000 ]]; then
    DISK="$name"
    break
  fi
done < <(lsblk -bdnpo NAME,TYPE,TRAN,SIZE,MODEL)

if [[ -z "$DISK" ]]; then
  echo "ERRO: SSD interno nao identificado com seguranca."
  lsblk -o NAME,MODEL,SIZE,FSTYPE,TYPE,TRAN
  exit 2
fi

echo "SSD interno detectado: $DISK"

EFI_PART=""
ROOT_PART=""
MAX=0
while read -r name fstype size type parttype; do
  [[ "$type" == "part" ]] || continue
  if [[ "$fstype" == "vfat" || "$fstype" == "fat32" ]]; then
    if [[ "$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" || "$size" -lt 2147483648 ]]; then
      [[ -z "$EFI_PART" ]] && EFI_PART="$name"
    fi
  fi
  if [[ "$fstype" == "ext4" && "$size" -gt "$MAX" ]]; then
    ROOT_PART="$name"
    MAX="$size"
  fi
done < <(lsblk -bnrpo NAME,FSTYPE,SIZE,TYPE,PARTTYPE "$DISK")

if [[ -z "$EFI_PART" || -z "$ROOT_PART" ]]; then
  echo "ERRO: nao consegui identificar automaticamente as particoes."
  lsblk -o NAME,MODEL,SIZE,FSTYPE,TYPE,PARTTYPE "$DISK"
  exit 3
fi

echo "Raiz: $ROOT_PART"
echo "EFI : $EFI_PART"

MNT=/mnt/nexhash-repair
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$EFI_PART" "$MNT/boot/efi"

for d in dev dev/pts proc sys run; do
  mount --rbind "/$d" "$MNT/$d"
  mount --make-rslave "$MNT/$d"
done

if [[ -e /etc/resolv.conf ]]; then
  cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
fi

cleanup() {
  set +e
  for d in run sys proc dev/pts dev; do umount -R "$MNT/$d" 2>/dev/null || true; done
  umount "$MNT/boot/efi" 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

chroot "$MNT" /bin/bash -eux <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr
mkdir -p /boot/efi/EFI/nexhash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=nexhash --uefi-secure-boot --recheck
update-grub

# Also populate the standard removable-media fallback path for stubborn firmware.
mkdir -p /boot/efi/EFI/BOOT
if [[ -f /boot/efi/EFI/nexhash/shimx64.efi ]]; then
  cp -f /boot/efi/EFI/nexhash/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
fi
if [[ -f /boot/efi/EFI/nexhash/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/nexhash/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
fi
if [[ -f /boot/efi/EFI/nexhash/mmx64.efi ]]; then
  cp -f /boot/efi/EFI/nexhash/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi
fi

echo
echo "EFI files:"
find /boot/efi/EFI -maxdepth 2 -type f -printf '%p\n' | sort
echo
efibootmgr -v || true
CHROOT

sync
echo
echo "REPAIR_OK"
echo "Desligue o notebook, retire o pendrive e ligue normalmente."
