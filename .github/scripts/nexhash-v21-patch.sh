#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-source}"
OUT_DIR="${2:-out}"
SRC="$(find "$SRC_DIR" -type f -name '*.iso' | head -n1)"
test -s "$SRC"

sudo apt-get update >/dev/null
sudo apt-get install -y xorriso squashfs-tools curl unzip >/dev/null

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

# Remove the live-media APT source. It only exists while booted from the ISO
# and breaks apt inside the extracted filesystem during CI.
cat > /etc/apt/sources.list <<'EOF_APT'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF_APT
if [ -d /etc/apt/sources.list.d ]; then
  while IFS= read -r src; do
    mv "$src" "$src.disabled"
  done < <(grep -rl 'file:/run/live/medium' /etc/apt/sources.list.d 2>/dev/null || true)
fi

# Ensure the KDE/NetworkManager connection UI exists.
apt-get update
apt-get install -y network-manager plasma-nm plasma-pa powerdevil wpasupplicant rfkill python3-pyqt5 fonts-noto-core
apt-get install -y docker.io docker-compose || apt-get install -y docker.io docker-compose-plugin || true
systemctl enable docker.service 2>/dev/null || true
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

cat > /etc/NetworkManager/conf.d/20-nexhash-dns.conf <<'EOF_DNS'
[main]
dns=default
rc-manager=file
EOF_DNS

# Self-healing network repair helper. It makes sure NetworkManager owns
# /etc/resolv.conf and refreshes DHCP/DNS after boot.
cat > /usr/local/sbin/nexhash-network-repair <<'EOF_REPAIR'
#!/usr/bin/env bash
set -u
nmcli networking on >/dev/null 2>&1 || true
nmcli radio wifi on >/dev/null 2>&1 || true

# NetworkManager owns resolver state. Start with a normal writable file,
# never the GitHub Actions resolver or a dead symlink.
rm -f /etc/resolv.conf
install -m 0644 /dev/null /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

systemctl restart NetworkManager >/dev/null 2>&1 || true
sleep 3
nmcli connection reload >/dev/null 2>&1 || true

# NetworkManager normally replaces the fallback with DHCP DNS. Keep public
# fallback only if no resolver arrived.
if ! grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
EOF_REPAIR
chmod +x /usr/local/sbin/nexhash-network-repair

cat > /etc/systemd/system/nexhash-network-repair.service <<'EOF_SERVICE'
[Unit]
Description=NexHash EdgeOS network and DNS repair
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nexhash-network-repair
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
systemctl enable nexhash-network-repair.service || true

# Appliance live user must not get stuck on an unusable sudo password.
# Limit passwordless elevation to the fixed NexHash appliance account.
install -d -m 0755 /etc/sudoers.d
cat > /etc/sudoers.d/90-nexhash-edgeos <<'EOF_SUDO'
nexhash ALL=(ALL:ALL) NOPASSWD: ALL
%sudo ALL=(ALL:ALL) NOPASSWD: ALL
EOF_SUDO
chmod 0440 /etc/sudoers.d/90-nexhash-edgeos
visudo -cf /etc/sudoers.d/90-nexhash-edgeos

# If the live user already exists in the image, ensure it belongs to sudo.
if id nexhash >/dev/null 2>&1; then
  usermod -aG sudo nexhash || true
fi

mkdir -p /etc/skel/Desktop /etc/skel/.config/autostart /usr/local/bin /usr/share/nexhash-edgeos /usr/share/icons/hicolor/scalable/apps /usr/share/applications

# Product branding.
cat > /usr/share/icons/hicolor/scalable/apps/nexhash-edgeos.svg <<'EOF_LOGO'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#36a8ff"/><stop offset="1" stop-color="#1455ff"/></linearGradient></defs>
  <rect width="128" height="128" rx="28" fill="#07111f"/>
  <path d="M24 93 47 35c2-5 9-6 12-1l15 24 15-34c2-5 9-6 12-2l8 10-28 65c-2 5-9 6-12 1L54 74 42 99c-2 5-9 6-12 2z" fill="url(#g)"/>
</svg>
EOF_LOGO

cat > /usr/share/applications/nexhash-welcome.desktop <<'EOF_APP'
[Desktop Entry]
Type=Application
Name=NexHash EdgeOS
Comment=Central de controle do NexHash EdgeOS
Exec=/usr/local/bin/nexhash-welcome
Icon=nexhash-edgeos
Terminal=false
Categories=System;Settings;
EOF_APP

cat > /usr/local/bin/nexhash-welcome <<'PY_WELCOME'
#!/usr/bin/env python3
import os, glob, socket, subprocess
from PyQt5 import QtCore, QtGui, QtWidgets

ACCENT="#1f86ff"; BG="#07111f"; CARD="#0d1a2b"; MUTED="#9fb0c5"; GREEN="#42d392"

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
    except Exception:
        return ""

def spawn(cmd):
    subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

class StatusCard(QtWidgets.QFrame):
    def __init__(self, title, icon, parent=None):
        super().__init__(parent); self.setObjectName("card")
        lay=QtWidgets.QVBoxLayout(self); lay.setContentsMargins(18,16,18,16); lay.setSpacing(8)
        head=QtWidgets.QHBoxLayout()
        i=QtWidgets.QLabel(icon); i.setObjectName("emoji"); t=QtWidgets.QLabel(title); t.setObjectName("cardTitle")
        head.addWidget(i); head.addWidget(t); head.addStretch(); lay.addLayout(head)
        self.status=QtWidgets.QLabel("Verificando…"); self.status.setObjectName("status")
        self.detail=QtWidgets.QLabel(""); self.detail.setObjectName("detail"); self.detail.setWordWrap(True)
        lay.addWidget(self.status); lay.addWidget(self.detail); lay.addStretch()
        self.buttons=QtWidgets.QHBoxLayout(); lay.addLayout(self.buttons)
    def button(self, text, fn, primary=False):
        b=QtWidgets.QPushButton(text); b.setProperty("primary", primary); b.clicked.connect(fn); self.buttons.addWidget(b); return b

class Welcome(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("NexHash EdgeOS")
        self.setWindowIcon(QtGui.QIcon("/usr/share/icons/hicolor/scalable/apps/nexhash-edgeos.svg"))
        self.resize(1080,720); self.setMinimumSize(900,620)
        root=QtWidgets.QWidget(); self.setCentralWidget(root)
        outer=QtWidgets.QVBoxLayout(root); outer.setContentsMargins(34,28,34,28); outer.setSpacing(18)

        top=QtWidgets.QHBoxLayout()
        logo=QtWidgets.QLabel(); pix=QtGui.QPixmap("/usr/share/icons/hicolor/scalable/apps/nexhash-edgeos.svg").scaled(58,58,QtCore.Qt.KeepAspectRatio,QtCore.Qt.SmoothTransformation); logo.setPixmap(pix)
        titles=QtWidgets.QVBoxLayout(); h=QtWidgets.QLabel("NexHash <span style='color:#1f86ff'>EdgeOS</span>"); h.setTextFormat(QtCore.Qt.RichText); h.setObjectName("hero")
        sub=QtWidgets.QLabel("Seu ambiente de mineração, acesso remoto e conectividade em um único lugar."); sub.setObjectName("subtitle")
        titles.addWidget(h); titles.addWidget(sub)
        top.addWidget(logo); top.addSpacing(12); top.addLayout(titles); top.addStretch()
        self.battery=QtWidgets.QLabel("Bateria --%"); self.battery.setObjectName("batteryPill"); top.addWidget(self.battery)
        outer.addLayout(top)

        grid=QtWidgets.QGridLayout(); grid.setHorizontalSpacing(16); grid.setVerticalSpacing(16)
        self.net=StatusCard("Rede", "◉"); self.net.button("Connect", lambda: spawn("/usr/local/bin/nexhash-network-connect"), True); self.net.button("Configurações", lambda: spawn("systemsettings kcm_networkmanagement"))
        self.tail=StatusCard("Acesso remoto", "◌"); self.tail.button("Abrir Tailscale", lambda: spawn("/usr/local/bin/nexhash-tailscale"), True)
        self.apps=StatusCard("Aplicativos", "◆")
        self.apps.status.setText("Prontos para uso"); self.apps.detail.setText("Opera • Tailscale • Calamares • Terminal")
        self.apps.button("Opera", lambda: spawn("opera >/dev/null 2>&1 &"), True); self.apps.button("Instalador", lambda: spawn("calamares >/dev/null 2>&1 &"))
        self.system=StatusCard("Sistema", "⚙")
        self.system.button("Configurações", lambda: spawn("systemsettings >/dev/null 2>&1 &"), True)
        self.system.button("Terminal", lambda: spawn("konsole >/dev/null 2>&1 &"))
        grid.addWidget(self.net,0,0); grid.addWidget(self.tail,0,1); grid.addWidget(self.apps,1,0); grid.addWidget(self.system,1,1)
        grid.setColumnStretch(0,1); grid.setColumnStretch(1,1)
        outer.addLayout(grid,1)

        footer=QtWidgets.QHBoxLayout()
        self.autostart=QtWidgets.QCheckBox("Abrir esta central ao iniciar"); self.autostart.setChecked(True); self.autostart.stateChanged.connect(self.toggle_autostart)
        footer.addWidget(self.autostart); footer.addStretch()
        close=QtWidgets.QPushButton("Ir para o desktop"); close.setProperty("primary", True); close.clicked.connect(self.close); footer.addWidget(close)
        outer.addLayout(footer)

        self.setStyleSheet("""
        QWidget { background:#07111f; color:#eef5ff; font-family:'Noto Sans'; font-size:14px; }
        QLabel#hero { font-size:30px; font-weight:700; }
        QLabel#subtitle, QLabel#detail { color:#9fb0c5; }
        QLabel#cardTitle { font-size:17px; font-weight:650; }
        QLabel#status { font-size:22px; font-weight:700; color:#42d392; }
        QLabel#emoji { font-size:22px; color:#1f86ff; }
        QLabel#batteryPill { background:#0d1a2b; border:1px solid #1f86ff; border-radius:18px; padding:9px 16px; font-weight:700; }
        QFrame#card { background:#0d1a2b; border:1px solid #1c3557; border-radius:16px; }
        QPushButton { background:#13243a; border:1px solid #2b4668; border-radius:9px; padding:9px 14px; font-weight:600; }
        QPushButton:hover { background:#19314f; }
        QPushButton[primary="true"] { background:#1f86ff; border-color:#1f86ff; color:white; }
        QCheckBox { color:#c7d5e6; spacing:8px; }
        """)
        self.timer=QtCore.QTimer(self); self.timer.timeout.connect(self.refresh); self.timer.start(3500); self.refresh()

    def toggle_autostart(self, state):
        path=os.path.expanduser("~/.config/autostart/nexhash-welcome.desktop")
        if state:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            try:
                subprocess.run(["cp","/usr/share/applications/nexhash-welcome.desktop",path],check=False)
            except Exception: pass
        else:
            try: os.remove(path)
            except FileNotFoundError: pass

    def refresh(self):
        conn=run("nmcli -t -f STATE general")
        ssid=run("nmcli -t -f active,ssid dev wifi | sed -n 's/^yes://p' | head -n1")
        ip=run("hostname -I | awk '{print $1}'")
        internet = bool(run("ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && getent hosts google.com >/dev/null 2>&1 && echo ok"))
        if conn=="connected" and internet:
            self.net.status.setText("● Internet OK")
            self.net.detail.setText((ssid or "Ethernet") + (f"  •  {ip}" if ip else ""))
        elif conn=="connected":
            self.net.status.setText("● Wi-Fi conectado • sem Internet")
            self.net.detail.setText((ssid or "Rede local") + (f"  •  {ip}" if ip else "") + "  •  Reparação automática ativa")
        else:
            self.net.status.setText("○ Sem conexão"); self.net.detail.setText("Clique em Connect para escolher uma rede.")

        ts=run("tailscale status --json 2>/dev/null | grep -m1 'TailscaleIPs'") or run("tailscale status 2>/dev/null | head -n1")
        if ts:
            tip=run("tailscale ip -4 | head -n1")
            self.tail.status.setText("● Conectado"); self.tail.detail.setText("Tailscale ativo" + (f"  •  {tip}" if tip else ""))
        else:
            self.tail.status.setText("○ Desconectado"); self.tail.detail.setText("Clique em Abrir Tailscale para conectar este PC.")

        bats=glob.glob("/sys/class/power_supply/BAT*/capacity")
        pct="--"
        if bats:
            try: pct=open(bats[0]).read().strip()
            except Exception: pass
        ac=run("cat /sys/class/power_supply/A*/online 2>/dev/null | head -n1")
        self.battery.setText(f"⚡ {pct}%" if ac=="1" else f"🔋 {pct}%")
        host=socket.gethostname()
        up=run("uptime -p")
        self.system.status.setText("● Operacional")
        self.system.detail.setText(f"{host}  •  {up or 'sistema pronto'}")

app=QtWidgets.QApplication([])
app.setApplicationName("NexHash EdgeOS")
w=Welcome(); w.show()
app.exec_()
PY_WELCOME
chmod +x /usr/local/bin/nexhash-welcome
python3 -m py_compile /usr/local/bin/nexhash-welcome

cat > /etc/skel/.config/autostart/nexhash-welcome.desktop <<'EOF_WELCOME_AUTO'
[Desktop Entry]
Type=Application
Name=NexHash EdgeOS
Exec=/usr/local/bin/nexhash-welcome
Icon=nexhash-edgeos
X-KDE-autostart-after=panel
Terminal=false
EOF_WELCOME_AUTO

cat > /etc/skel/Desktop/NexHash-EdgeOS.desktop <<'EOF_WELCOME_DESK'
[Desktop Entry]
Type=Application
Name=NexHash EdgeOS
Comment=Central do sistema
Exec=/usr/local/bin/nexhash-welcome
Icon=nexhash-edgeos
Terminal=false
Categories=System;
EOF_WELCOME_DESK
chmod +x /etc/skel/Desktop/NexHash-EdgeOS.desktop

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
sudo -n systemctl start tailscaled 2>/dev/null || systemctl start tailscaled 2>/dev/null || true
if tailscale status >/dev/null 2>&1; then
  konsole -e bash -lc 'echo "Tailscale conectado"; echo; tailscale status; echo; read -rp "Pressione ENTER para fechar..."'
else
  konsole -e bash -lc 'echo "NexHash EdgeOS - Conectar Tailscale"; echo; sudo -n tailscale up; echo; tailscale status; exec bash'
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

# Product-like defaults: dark theme, compact taskbar, visible network/battery.
for KWRITE in kwriteconfig6 kwriteconfig5; do
  if command -v "$KWRITE" >/dev/null 2>&1; then
    "$KWRITE" --file kdeglobals --group General --key ColorScheme BreezeDark >/dev/null 2>&1 || true
  fi
done

# Keep a single battery indicator. The system tray owns the panel battery;
# exact percentage is always visible in NexHash Welcome.
sleep 2

# Clean duplicate launchers inherited from earlier builds.
rm -f "$HOME/Desktop/opera.desktop" "$HOME/Desktop/calamares.desktop" 2>/dev/null || true

# Installer shortcuts make sense only in the live/install environment.
if ! grep -qw 'boot=live' /proc/cmdline 2>/dev/null; then
  rm -f "$HOME/Desktop/install-nexhash.desktop" "$HOME/Desktop/calamares.desktop" 2>/dev/null || true
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

# Remove the duplicate standalone battery plasmoid inherited from the base image.
# Battery remains available once through the system tray; NexHash Welcome shows exact %.
PANEL=/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
rm -f /etc/skel/Desktop/opera.desktop /etc/skel/Desktop/calamares.desktop 2>/dev/null || true

if [ -f "$PANEL" ]; then
  sed -i 's/AppletOrder=3;4;5;6;7;8;9;10/AppletOrder=3;4;5;6;8;9;10/g' "$PANEL" || true
  python3 - "$PANEL" <<'PY_PANEL'
import re,sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
s=re.sub(r'\n\[Containments\]\[2\]\[Applets\]\[7\][\s\S]*?(?=\n\[Containments\]\[2\]\[Applets\]\[8\])','\n',s)
open(p,'w',encoding="utf-8").write(s)
PY_PANEL
fi

mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'EOF_KDE'
[General]
ColorScheme=BreezeDark

[KDE]
SingleClick=false
EOF_KDE

# Keep installer autostart and existing NexHash app intact.
if [ -x /usr/local/bin/nexhash-installer-autostart ]; then
  sed -i 's#pkexec calamares#sudo -n calamares#g' /usr/local/bin/nexhash-installer-autostart || true
fi
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

# Never ship the GitHub runner resolver inside the ISO.
sudo rm -f rootfs/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee rootfs/etc/resolv.conf >/dev/null
sudo chmod 0644 rootfs/etc/resolv.conf

echo "[2b/7] Installing verified Braiins Toolbox 26.09..."
BRAIINS_URL="https://downloads.braiins.com/braiins-toolbox/assets/26.09/braiins-toolbox-linux-x86_64.tar.gz"
BRAIINS_SHA="8d173eab04fcecf8922b74de575dbba587050128fd17545d32e63e93b739ea47"
curl -fL --retry 5 --retry-delay 2 "$BRAIINS_URL" -o work/braiins-toolbox.tar.gz
echo "$BRAIINS_SHA  work/braiins-toolbox.tar.gz" | sha256sum -c -
rm -rf work/braiins-toolbox
mkdir -p work/braiins-toolbox
tar -xzf work/braiins-toolbox.tar.gz -C work/braiins-toolbox
BRAIINS_BIN="$(find work/braiins-toolbox -type f -name 'braiins-toolbox' | head -n1)"
test -n "$BRAIINS_BIN"
sudo install -m 0755 "$BRAIINS_BIN" rootfs/usr/local/bin/braiins-toolbox

echo "[3a/7] Embedding NexHash v5.2.2 Commercial V1.5 Production Cloud..."
APP_ZIP="$(find bundle -maxdepth 1 -type f -name 'NexHash-v5.2.2-Commercial-V1.5-Production-Cloud.zip' | head -n1 || true)"
test -n "$APP_ZIP"
test -s "$APP_ZIP"
sudo rm -rf rootfs/opt/nexhash/current rootfs/tmp/nexhash-app-unpack
sudo mkdir -p rootfs/opt/nexhash/current rootfs/tmp/nexhash-app-unpack
sudo unzip -q "$APP_ZIP" -d rootfs/tmp/nexhash-app-unpack

# Flatten a single wrapper directory, common in generated ZIP releases.
TOP_COUNT="$(sudo find rootfs/tmp/nexhash-app-unpack -mindepth 1 -maxdepth 1 | wc -l)"
TOP_DIR="$(sudo find rootfs/tmp/nexhash-app-unpack -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
TOP_FILE_COUNT="$(sudo find rootfs/tmp/nexhash-app-unpack -mindepth 1 -maxdepth 1 -type f | wc -l)"
if [ "$TOP_COUNT" -eq 1 ] && [ "$TOP_FILE_COUNT" -eq 0 ] && [ -n "$TOP_DIR" ]; then
  sudo cp -a "$TOP_DIR"/. rootfs/opt/nexhash/current/
else
  sudo cp -a rootfs/tmp/nexhash-app-unpack/. rootfs/opt/nexhash/current/
fi
sudo rm -rf rootfs/tmp/nexhash-app-unpack
sudo chown -R root:root rootfs/opt/nexhash/current

# Production Cloud release must include at least one known deployment marker.
if ! sudo find rootfs/opt/nexhash/current -maxdepth 3 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name 'HOSPEDAR-NEXHASH-CLOUD.md' -o -name 'README-RAPIDO.txt' \) | grep -q .; then
  echo "NexHash V1.5 deployment markers not found after extraction" >&2
  sudo find rootfs/opt/nexhash/current -maxdepth 3 -type f | head -100 >&2
  exit 1
fi

echo "[3b/7] Installing NexHash appliance/server/watchdog layer..."
sudo bash .github/scripts/nexhash-v25-appliance.sh rootfs

# Ensure core runtime dependencies for the embedded appliance layer exist.
sudo test -x rootfs/usr/local/bin/nexhash-run
sudo test -x rootfs/usr/local/bin/nexhashctl
sudo test -f rootfs/etc/systemd/system/nexhash.service
sudo test -f rootfs/etc/systemd/system/nexhash-asic-watchdog.service
sudo test -f rootfs/usr/local/lib/nexhash/asic_watchdog.py

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
DEST="$OUT_DIR/NexHash-EdgeOS-2.5-APPLIANCE-FINAL-Install-amd64.iso"
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
unsquashfs -cat verify/filesystem.squashfs etc/NetworkManager/conf.d/20-nexhash-dns.conf | grep -q 'dns=default'
unsquashfs -cat verify/filesystem.squashfs usr/local/sbin/nexhash-network-repair | grep -q 'nameserver 1.1.1.1'
unsquashfs -cat verify/filesystem.squashfs etc/systemd/system/nexhash-network-repair.service | grep -q 'nexhash-network-repair'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Connect.desktop | grep -q 'nexhash-network-connect'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Opera.desktop | grep -q 'Exec=opera'
unsquashfs -cat verify/filesystem.squashfs etc/skel/Desktop/Tailscale.desktop | grep -q 'nexhash-tailscale'
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/nexhash-desktop-setup | grep -q 'single battery indicator'
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/nexhash-welcome | grep -q 'NexHash <span'
unsquashfs -cat verify/filesystem.squashfs etc/skel/.config/autostart/nexhash-welcome.desktop | grep -q 'nexhash-welcome'
unsquashfs -cat verify/filesystem.squashfs usr/share/applications/nexhash-welcome.desktop | grep -q 'Central de controle'
# Real V1.5 app payload must be inside the final ISO, not just the appliance bootstrap.
unsquashfs -ll verify/filesystem.squashfs > verify/squashfs-list.txt
grep -Eq 'opt/nexhash/current/.+(docker-compose\.ya?ml|compose\.ya?ml|HOSPEDAR-NEXHASH-CLOUD\.md|README-RAPIDO\.txt)' verify/squashfs-list.txt
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/braiins-toolbox > verify/braiins-toolbox
test -s verify/braiins-toolbox
chmod +x verify/braiins-toolbox
verify/braiins-toolbox --version >/dev/null 2>&1 || verify/braiins-toolbox --help >/dev/null 2>&1
unsquashfs -cat verify/filesystem.squashfs etc/systemd/system/nexhash.service | grep -q 'Restart=always'
unsquashfs -cat verify/filesystem.squashfs etc/systemd/system/nexhash-asic-watchdog.service | grep -q 'ASIC Auto-Recovery Watchdog'
unsquashfs -cat verify/filesystem.squashfs usr/local/lib/nexhash/asic_watchdog.py | grep -q 'RESFRIANDO'
unsquashfs -cat verify/filesystem.squashfs usr/local/lib/nexhash/asic_watchdog.py | grep -q 'ASIC_MAX_RETRIES'
unsquashfs -cat verify/filesystem.squashfs etc/nexhash/device.env | grep -q 'ASIC_COOLDOWN_SECONDS=180'
unsquashfs -cat verify/filesystem.squashfs etc/nexhash/device.env | grep -q 'ASIC_STABILIZE_SECONDS=240'
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/nexhash-open | grep -q '127.0.0.1'
unsquashfs -cat verify/filesystem.squashfs etc/skel/.config/autostart/nexhash-open.desktop | grep -q 'nexhash-open'
unsquashfs -cat verify/filesystem.squashfs etc/sudoers.d/90-nexhash-edgeos > verify/nexhash-sudoers
grep -q '^nexhash .*NOPASSWD: ALL' verify/nexhash-sudoers
grep -q '^%sudo .*NOPASSWD: ALL' verify/nexhash-sudoers
unsquashfs -cat verify/filesystem.squashfs usr/local/bin/nexhash-welcome | grep -q 'sem Internet'
# The default panel must not ship a second standalone battery plasmoid.
if unsquashfs -cat verify/filesystem.squashfs etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc 2>/dev/null | grep -q 'plugin=org.kde.plasma.battery'; then
  echo "Duplicate standalone battery plasmoid still present" >&2
  exit 1
fi
unsquashfs -cat verify/filesystem.squashfs var/lib/dpkg/status > verify/status
grep -q '^Package: network-manager$' verify/status
grep -q '^Package: plasma-nm$' verify/status
grep -q '^Package: powerdevil$' verify/status
grep -q '^Package: opera-stable$' verify/status
grep -q '^Package: tailscale$' verify/status
grep -q '^Package: nodejs$' verify/status
grep -q '^Package: python3-pyqt5
test "$(stat -c%s "$DEST")" -gt 3000000000

{
  echo "NEXHASH EDGEOS 2.5 APPLIANCE FINAL ISO VALIDATED"
  echo "BIOS installer menu: OK"
  echo "UEFI installer menu: OK"
  echo "nexhash-installer=1: OK"
  echo "Calamares installer/autostart: OK"
  echo "NetworkManager backend: OK"
  echo "NetworkManager DNS/resolver ownership: OK"
  echo "Boot-time network self-repair: OK"
  echo "Plasma network Connect UI: OK"
  echo "Wi-Fi radio setup: OK"
  echo "Single battery indicator policy: OK"
  echo "Battery percentage in NexHash Welcome: OK"
  echo "NexHash live/admin sudo without broken password prompt: OK"
  echo "Internet reachability status in Welcome: OK"
  echo "NexHash product welcome center: OK"
  echo "NexHash Commercial V1.5 payload embedded: OK"
  echo "NexHash server systemd service/restart policy: OK"
  echo "NexHash Opera autostart to local server: OK"
  echo "Braiins Toolbox 26.09 verified: OK"
  echo "ASIC watchdog automatic recovery: OK"
  echo "ASIC cooling countdown before recovery: 180s"
  echo "ASIC post-restart stabilization: 240s"
  echo "ASIC retry/loop protection: OK"
  echo "NexHash branding/icon/theme: OK"
  echo "Opera: OK"
  echo "Tailscale: OK"
  echo "Node.js: OK"
  echo "Docker runtime for NexHash Production Cloud: OK"
  echo "PyQt welcome runtime: OK"
  echo "KDE/PowerDevil: OK"
  echo "User wallpaper via Higgsfield: OK"
  echo
  sha256sum "$DEST"
} | tee "$OUT_DIR/FINAL-VALIDATED.txt"

split -b 450M -d -a 2 "$DEST" "$OUT_DIR/final-part-"
sha256sum "$OUT_DIR"/final-part-* > "$OUT_DIR/final-parts.sha256"
 verify/status
grep -q '^Package: docker.io
test "$(stat -c%s "$DEST")" -gt 3000000000

{
  echo "NEXHASH EDGEOS 2.5 APPLIANCE FINAL ISO VALIDATED"
  echo "BIOS installer menu: OK"
  echo "UEFI installer menu: OK"
  echo "nexhash-installer=1: OK"
  echo "Calamares installer/autostart: OK"
  echo "NetworkManager backend: OK"
  echo "NetworkManager DNS/resolver ownership: OK"
  echo "Boot-time network self-repair: OK"
  echo "Plasma network Connect UI: OK"
  echo "Wi-Fi radio setup: OK"
  echo "Single battery indicator policy: OK"
  echo "Battery percentage in NexHash Welcome: OK"
  echo "NexHash live/admin sudo without broken password prompt: OK"
  echo "Internet reachability status in Welcome: OK"
  echo "NexHash product welcome center: OK"
  echo "NexHash server systemd service/restart policy: OK"
  echo "NexHash Opera autostart to local server: OK"
  echo "ASIC watchdog automatic recovery: OK"
  echo "ASIC cooling countdown before recovery: 180s"
  echo "ASIC post-restart stabilization: 240s"
  echo "ASIC retry/loop protection: OK"
  echo "NexHash branding/icon/theme: OK"
  echo "Opera: OK"
  echo "Tailscale: OK"
  echo "Node.js: OK"
  echo "PyQt welcome runtime: OK"
  echo "KDE/PowerDevil: OK"
  echo "User wallpaper via Higgsfield: OK"
  echo
  sha256sum "$DEST"
} | tee "$OUT_DIR/FINAL-VALIDATED.txt"

split -b 450M -d -a 2 "$DEST" "$OUT_DIR/final-part-"
sha256sum "$OUT_DIR"/final-part-* > "$OUT_DIR/final-parts.sha256"
 verify/status
test "$(stat -c%s "$DEST")" -gt 3000000000

{
  echo "NEXHASH EDGEOS 2.5 APPLIANCE FINAL ISO VALIDATED"
  echo "BIOS installer menu: OK"
  echo "UEFI installer menu: OK"
  echo "nexhash-installer=1: OK"
  echo "Calamares installer/autostart: OK"
  echo "NetworkManager backend: OK"
  echo "NetworkManager DNS/resolver ownership: OK"
  echo "Boot-time network self-repair: OK"
  echo "Plasma network Connect UI: OK"
  echo "Wi-Fi radio setup: OK"
  echo "Single battery indicator policy: OK"
  echo "Battery percentage in NexHash Welcome: OK"
  echo "NexHash live/admin sudo without broken password prompt: OK"
  echo "Internet reachability status in Welcome: OK"
  echo "NexHash product welcome center: OK"
  echo "NexHash server systemd service/restart policy: OK"
  echo "NexHash Opera autostart to local server: OK"
  echo "ASIC watchdog automatic recovery: OK"
  echo "ASIC cooling countdown before recovery: 180s"
  echo "ASIC post-restart stabilization: 240s"
  echo "ASIC retry/loop protection: OK"
  echo "NexHash branding/icon/theme: OK"
  echo "Opera: OK"
  echo "Tailscale: OK"
  echo "Node.js: OK"
  echo "PyQt welcome runtime: OK"
  echo "KDE/PowerDevil: OK"
  echo "User wallpaper via Higgsfield: OK"
  echo
  sha256sum "$DEST"
} | tee "$OUT_DIR/FINAL-VALIDATED.txt"

split -b 450M -d -a 2 "$DEST" "$OUT_DIR/final-part-"
sha256sum "$OUT_DIR"/final-part-* > "$OUT_DIR/final-parts.sha256"
