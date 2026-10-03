#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-source}"
OUT_DIR="${2:-out}"
SRC="$(find "$SRC_DIR" -type f -name '*.iso' | head -n1)"
test -s "$SRC"

sudo apt-get update >/dev/null
sudo apt-get install -y xorriso squashfs-tools curl >/dev/null

rm -rf work rootfs "$OUT_DIR"
mkdir -p work rootfs "$OUT_DIR"

echo "[1/7] Extracting live filesystem..."
xorriso -osirrox on -indev "$SRC" -extract /live/filesystem.squashfs work/filesystem.squashfs >/dev/null 2>&1
sudo unsquashfs -d rootfs work/filesystem.squashfs >/dev/null

echo "[2/7] Installing exact user wallpaper from Higgsfield..."
sudo mkdir -p rootfs/usr/share/backgrounds/nexhash rootfs/etc/skel/Pictures
sudo curl -fL --retry 5 --retry-delay 2   "https://d2ol7oe51mr4n9.cloudfront.net/user_3JpqLrtojdNZKMbC1DzLsTTI5W4/6ab2bf8a-34fe-446c-a4b5-4f433b5d50fa.png"   -o rootfs/usr/share/backgrounds/nexhash/edgeos-wallpaper.png
sudo cp rootfs/usr/share/backgrounds/nexhash/edgeos-wallpaper.png rootfs/etc/skel/Pictures/NexHash-EdgeOS.png

echo "[3/7] Fixing NetworkManager, Plasma network UI, Tailscale, Opera and battery UI..."
sudo rm -f rootfs/etc/resolv.conf
sudo cp /etc/resolv.conf rootfs/etc/resolv.conf
for d in dev proc sys; do sudo mount --bind "/$d" "rootfs/$d"; done
cleanup() {
  for d in dev proc sys; do sudo umount -lf "rootfs/$d" 2>/dev/null || true; done
}
trap cleanup EXIT

sudo tee rootfs/tmp/nexhash-v21-rootfs.sh >/dev/null <<'ROOTFS_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Ensure the KDE/NetworkManager connection UI exists.
apt-get update
apt-get install -y network-manager plasma-nm plasma-pa powerdevil wpasupplicant rfkill
apt-get install -y network-manager-gnome wireless-tools || true
apt-get install -y firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 || true

systemctl enable NetworkManager.service || true
systemctl enable tailscaled.service || true
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-nexhash.conf <<'EOF_NM'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
EOF_NM

mkdir -p /etc/skel/Desktop /etc/skel/.config/autostart /usr/local/bin

cat > /usr/local/bin/nexhash-network-connect <<'EOF_CONNECT'
#!/usr/bin/env bash
set -u
nmcli networking on >/dev/null 2>&1 || true
nmcli radio wifi on >/dev/null 2>&1 || true
if command -v plasma-open-settings >/dev/null 2>&1; then
  plasma-open-settings kcm_networkmanagement >/dev/null 2>&1 &
elif command -v systemsettings >/dev/null 2>&1; then
  systemsettings kcm_networkmanagement >/dev/null 2>&1 &
elif command -v nm-connection-editor >/dev/null 2>&1; then
  nm-connection-editor >/dev/null 2>&1 &
else
  konsole -e bash -lc 'nmcli device wifi rescan; nmcli device wifi list; exec bash'
fi
EOF_CONNECT
chmod +x /usr/local/bin/nexhash-network-connect

cat > /usr/local/bin/nexhash-tailscale <<'EOF_TSAPP'
#!/usr/bin/env bash
set -u
sudo systemctl start tailscaled 2>/dev/null || true
if tailscale status >/dev/null 2>&1; then
  konsole -e bash -lc 'echo "Tailscale conectado"; echo; tailscale status; echo; read -rp "Pressione ENTER para fechar..."'
else
  konsole -e bash -lc 'echo "NexHash EdgeOS - Conectar Tailscale"; echo; sudo tailscale up; echo; tailscale status; exec bash'
fi
EOF_TSAPP
chmod +x /usr/local/bin/nexhash-tailscale

cat > /usr/local/bin/nexhash-desktop-setup <<'EOF_SETUP'
#!/usr/bin/env bash
set -u
WALL="/usr/share/backgrounds/nexhash/edgeos-wallpaper.png"

if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
  plasma-apply-wallpaperimage "$WALL" >/dev/null 2>&1 || true
fi
if command -v lookandfeeltool >/dev/null 2>&1; then
  lookandfeeltool -a org.kde.breezedark.desktop >/dev/null 2>&1 || true
fi

nmcli networking on >/dev/null 2>&1 || true
nmcli radio wifi on >/dev/null 2>&1 || true

# Make battery percentage visible in the panel.
sleep 4
JS='var ps=panels(); if(ps.length>0){var p=ps[0],ws=p.widgets(),b=null; for(var i=0;i<ws.length;i++){if(ws[i].type=="org.kde.plasma.battery"){b=ws[i];break;}} if(!b){b=p.addWidget("org.kde.plasma.battery");} if(b){b.currentConfigGroup=["General"];b.writeConfig("showPercentage",true);b.writeConfig("showRemainingTime",true);}}'
if command -v qdbus6 >/dev/null 2>&1; then
  qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$JS" >/dev/null 2>&1 || true
elif command -v qdbus >/dev/null 2>&1; then
  qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$JS" >/dev/null 2>&1 || true
fi
EOF_SETUP
chmod +x /usr/local/bin/nexhash-desktop-setup

cat > /etc/skel/.config/autostart/nexhash-desktop-setup.desktop <<'EOF_AUTO'
[Desktop Entry]
Type=Application
Name=NexHash EdgeOS Desktop Setup
Exec=/usr/local/bin/nexhash-desktop-setup
X-KDE-autostart-after=panel
NoDisplay=true
EOF_AUTO

cat > /etc/skel/Desktop/Connect.desktop <<'EOF_DESKTOP_NET'
[Desktop Entry]
Type=Application
Name=Connect
Comment=Conectar Wi-Fi ou Ethernet
Exec=/usr/local/bin/nexhash-network-connect
Icon=network-wireless
Terminal=false
Categories=Network;
EOF_DESKTOP_NET

cat > /etc/skel/Desktop/Opera.desktop <<'EOF_DESKTOP_OPERA'
[Desktop Entry]
Type=Application
Name=Opera
Comment=Navegador
Exec=opera %U
Icon=opera
Terminal=false
Categories=Network;WebBrowser;
EOF_DESKTOP_OPERA

cat > /etc/skel/Desktop/Tailscale.desktop <<'EOF_DESKTOP_TS'
[Desktop Entry]
Type=Application
Name=Tailscale
Comment=Acesso remoto seguro
Exec=/usr/local/bin/nexhash-tailscale
Icon=network-vpn
Terminal=false
Categories=Network;
EOF_DESKTOP_TS

chmod +x /etc/skel/Desktop/*.desktop

mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'EOF_KDE'
[General]
ColorScheme=BreezeDark

[KDE]
SingleClick=false
EOF_KDE

# Keep installer autostart and existing NexHash app intact.
test -x /usr/local/bin/nexhash-installer-autostart
grep -q 'nexhash-installer=1' /usr/local/bin/nexhash-installer-autostart
command -v opera >/dev/null
command -v tailscale >/dev/null
command -v node >/dev/null
dpkg -s network-manager plasma-nm powerdevil >/dev/null
ROOTFS_SCRIPT

sudo chmod +x rootfs/tmp/nexhash-v21-rootfs.sh
sudo chroot rootfs /bin/bash /tmp/nexhash-v21-rootfs.sh
sudo rm -f rootfs/tmp/nexhash-v21-rootfs.sh
cleanup
trap - EXIT

echo "[4/7] Repacking live filesystem..."
sudo mksquashfs rootfs work/filesystem-new.squashfs -comp xz -b 1M -noappend >/dev/null

echo "[5/7] Preserving and validating BIOS/UEFI install entries..."
xorriso -osirrox on -indev "$SRC" -extract /isolinux/live.cfg work/live.cfg >/dev/null 2>&1
xorriso -osirrox on -indev "$SRC" -extract /boot/grub/grub.cfg work/grub.cfg >/dev/null 2>&1
chmod 0644 work/live.cfg work/grub.cfg

grep -q "Install NexHash EdgeOS" work/live.cfg
grep -q "nexhash-installer=1" work/live.cfg
grep -q "Install NexHash EdgeOS" work/grub.cfg
grep -q "nexhash-installer=1" work/grub.cfg

echo "[6/7] Building ISO..."
DEST="$OUT_DIR/NexHash-EdgeOS-2.1-FINAL-Install-amd64.iso"
xorriso   -indev "$SRC"   -outdev "$DEST"   -boot_image any replay   -map work/filesystem-new.squashfs /live/filesystem.squashfs   -commit >/dev/null

test -s "$DEST"
sha256sum "$DEST" > "$DEST.sha256"

echo "[7/7] Validating modified ISO..."
rm -rf verify
mkdir -p verify
xorriso -osirrox on -indev "$DEST" -extract /live/filesystem.squashfs verify/filesystem.squashfs >/dev/null 2>&1
xorriso -osirrox on -indev "$DEST" -extract /isolinux/live.cfg verify/live.cfg >/dev/null 2>&1
xorriso -osirrox on -indev "$DEST" -extract /boot/grub/grub.cfg verify/grub.cfg >/dev/null 2>&1

grep -q "Install NexHash EdgeOS" verify/live.cfg
grep -q "nexhash-installer=1" verify/live.cfg
grep -q "Install NexHash EdgeOS" verify/grub.cfg
grep -q "nexhash-installer=1" verify/grub.cfg

unsquashfs -cat verify/filesystem.squashfs usr/share/backgrounds/nexhash/edgeos-wallpaper.png > verify/wallpaper.png
test -s verify/wallpaper.png
unsquashfs -cat verify/filesystem.squashfs etc/NetworkManager/conf.d/10-nexhash.conf | grep -q 'managed=true'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Connect.desktop | grep -q 'nexhash-network-connect'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Opera.desktop | grep -q 'Exec=opera'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Tailscale.desktop | grep -q 'nexhash-tailscale'
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/nexhash-desktop-setup | grep -q 'showPercentage'
unsquashfs -cat verify/filesystem.squashfs var/lib/dpkg/status > verify/status
grep -q '^Package: network-manager$' verify/status
grep -q '^Package: plasma-nm$' verify/status
grep -q '^Package: powerdevil$' verify/status
grep -q '^Package: opera-stable$' verify/status
grep -q '^Package: tailscale$' verify/status
grep -q '^Package: nodejs$' verify/status
test "$(stat -c%s "$DEST")" -gt 3000000000

{
  echo "NEXHASH EDGEOS 2.1 FINAL ISO VALIDATED"
  echo "BIOS installer menu: OK"
  echo "UEFI installer menu: OK"
  echo "nexhash-installer=1: OK"
  echo "Calamares installer/autostart: OK"
  echo "NetworkManager backend: OK"
  echo "Plasma network Connect UI: OK"
  echo "Wi-Fi radio setup: OK"
  echo "Battery percentage visualization: OK"
  echo "Opera: OK"
  echo "Tailscale: OK"
  echo "Node.js: OK"
  echo "KDE/PowerDevil: OK"
  echo "User wallpaper via Higgsfield: OK"
  echo
  sha256sum "$DEST"
} | tee "$OUT_DIR/FINAL-VALIDATED.txt"

split -b 450M -d -a 2 "$DEST" "$OUT_DIR/final-part-"
sha256sum "$OUT_DIR"/final-part-* > "$OUT_DIR/final-parts.sha256"
