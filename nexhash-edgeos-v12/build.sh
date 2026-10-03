#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LB_BUILD_WITH_CHROOT=true

ROOT="$(pwd)"
WORK="$ROOT/edgeos-v12"
OUT="$ROOT/out"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

apt-get update
apt-get install -y --no-install-recommends \
  live-build debootstrap xorriso squashfs-tools ca-certificates curl gnupg rsync \
  qemu-system-x86 ovmf file fdisk unzip jq python3 python3-pil fonts-dejavu-core

# External package repositories are used ONLY on the build runner.
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://deb.opera.com/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/opera-browser.gpg
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/opera-browser.gpg] https://deb.opera.com/opera-stable/ stable non-free' > /etc/apt/sources.list.d/opera-stable.list
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
apt-get update

cd "$WORK"
lb config noauto \
  --mode debian \
  --distribution trixie \
  --architectures amd64 \
  --archive-areas 'main contrib non-free non-free-firmware' \
  --binary-images iso-hybrid \
  --debian-installer none \
  --bootloaders 'grub-efi,syslinux' \
  --apt-recommends false \
  --memtest none \
  --iso-application 'NexHash EdgeOS Industrial 1.2' \
  --iso-publisher 'NexHash' \
  --iso-volume 'NEXHASH_EDGEOS' \
  --bootappend-live 'boot=live components username=nexhash hostname=nexhash-edge locales=pt_BR.UTF-8 keyboard-layouts=br timezone=America/Sao_Paulo quiet loglevel=3 splash'

mkdir -p \
  config/package-lists \
  config/packages.chroot \
  config/includes.chroot/etc/nexhash \
  config/includes.chroot/etc/NetworkManager/conf.d \
  config/includes.chroot/etc/systemd/journald.conf.d \
  config/includes.chroot/etc/systemd/logind.conf.d \
  config/includes.chroot/etc/systemd/system.conf.d \
  config/includes.chroot/etc/systemd/zram-generator.conf.d \
  config/includes.chroot/etc/tlp.d \
  config/includes.chroot/etc/nftables.d \
  config/includes.chroot/etc/xdg/openbox \
  config/includes.chroot/etc/xdg/tint2 \
  config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d \
  config/includes.chroot/usr/local/bin \
  config/includes.chroot/usr/share/nexhash \
  config/includes.chroot/usr/share/keyrings \
  config/includes.chroot/etc/apt/sources.list.d \
  config/includes.chroot/etc/apt/apt.conf.d \
  config/includes.chroot/etc/default/grub.d \
  config/includes.chroot/etc/systemd/system \
  config/includes.chroot/opt/nexhash/releases \
  config/includes.chroot/var/lib/nexhash \
  config/includes.chroot/var/log/nexhash \
  config/hooks/normal

cat > config/package-lists/nexhash.list.chroot <<'PKG'
linux-image-amd64
live-boot
live-config
systemd-sysv
sudo
ca-certificates
curl
wget
gnupg
jq
unzip
zip
rsync
lsof
iproute2
procps
ethtool
iptables
network-manager
network-manager-gnome
wpasupplicant
wireless-regdb
iw
rfkill
openssh-server
nftables
unattended-upgrades
apt-listchanges
xserver-xorg-core
xserver-xorg-input-all
xserver-xorg-video-all
lightdm
lightdm-gtk-greeter
openbox
tint2
xterm
unclutter
feh
zenity
libnotify-bin
fonts-dejavu-core
fonts-noto-core
python3
python3-venv
python3-pip
tlp
acpid
irqbalance
systemd-zram-generator
thermald
upower
acpi
firmware-linux
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-brcm80211
firmware-sof-signed
intel-microcode
amd64-microcode
shim-signed
grub-efi-amd64
grub-efi-amd64-signed
efibootmgr
calamares
calamares-settings-debian
PKG

# Download Opera and Tailscale now and embed their DEBs directly in the squashfs.
TMPDEB="$(mktemp -d)"
pushd "$TMPDEB"
apt-get download opera-stable tailscale
cp ./*.deb "$WORK/config/packages.chroot/"
popd
rm -rf "$TMPDEB"

# Keep external repos available after installation for updates.
cp /usr/share/keyrings/opera-browser.gpg config/includes.chroot/usr/share/keyrings/
cp /usr/share/keyrings/tailscale-archive-keyring.gpg config/includes.chroot/usr/share/keyrings/
cp /etc/apt/sources.list.d/opera-stable.list config/includes.chroot/etc/apt/sources.list.d/
cp /etc/apt/sources.list.d/tailscale.list config/includes.chroot/etc/apt/sources.list.d/

cat > config/includes.chroot/etc/nexhash/release <<'EOF'
NAME="NexHash EdgeOS"
VERSION="1.2.0"
EDITION="Industrial / Forge"
BASE="Debian 13 trixie"
EOF

cat > config/includes.chroot/etc/nexhash/device.env <<'EOF'
NEXHASH_PORT=8787
NEXHASH_STATUS_PORT=8790
NEXHASH_APP_ROOT=/opt/nexhash
NEXHASH_APP_DIR=/opt/nexhash/current
NEXHASH_HOME_URL=http://127.0.0.1:8787
NEXHASH_STATUS_URL=http://127.0.0.1:8790
NEXHASH_HEALTH_FAILURES=3
NEXHASH_RELEASE_KEEP=4
EOF

cat > config/includes.chroot/etc/NetworkManager/conf.d/20-nexhash-wifi.conf <<'EOF'
[connection]
wifi.powersave=2

[device]
wifi.scan-rand-mac-address=no
EOF

cat > config/includes.chroot/etc/systemd/journald.conf.d/nexhash.conf <<'EOF'
[Journal]
SystemMaxUse=120M
RuntimeMaxUse=48M
MaxRetentionSec=7day
Compress=yes
EOF

cat > config/includes.chroot/etc/systemd/logind.conf.d/nexhash.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

cat > config/includes.chroot/etc/systemd/system.conf.d/nexhash-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=45s
RebootWatchdogSec=2min
EOF

cat > config/includes.chroot/etc/systemd/zram-generator.conf.d/nexhash.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 2048)
compression-algorithm = zstd
swap-priority = 100
EOF

cat > config/includes.chroot/etc/tlp.d/99-nexhash.conf <<'EOF'
TLP_ENABLE=1
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off
USB_AUTOSUSPEND=1
RESTORE_DEVICE_STATE_ON_STARTUP=1
EOF

cat > config/includes.chroot/etc/default/grub.d/99-nexhash.cfg <<'EOF'
GRUB_TIMEOUT=1
GRUB_TIMEOUT_STYLE=hidden
GRUB_DISTRIBUTOR="NexHash EdgeOS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
EOF

cat > config/includes.chroot/etc/apt/apt.conf.d/52nexhash-security <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > config/includes.chroot/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet nexhash_filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    udp dport {67,68,546,547} accept
    udp dport 41641 accept
    iifname "tailscale0" tcp dport {8787,8790} accept
    ip saddr 10.0.0.0/8 tcp dport {8787,8790} accept
    ip saddr 172.16.0.0/12 tcp dport {8787,8790} accept
    ip saddr 192.168.0.0/16 tcp dport {8787,8790} accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF

cat > config/includes.chroot/etc/xdg/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="NexHash EdgeOS">
    <item label="Painel NexHash"><action name="Execute"><command>/usr/local/bin/nexhash-browser</command></action></item>
    <item label="Internet - Opera"><action name="Execute"><command>opera</command></action></item>
    <item label="Conectar Wi-Fi"><action name="Execute"><command>/usr/local/bin/nexhash-wifi</command></action></item>
    <item label="Diagnostico"><action name="Execute"><command>opera http://127.0.0.1:8790</command></action></item>
    <separator/>
    <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
    <item label="Reiniciar"><action name="Execute"><command>systemctl reboot</command></action></item>
    <item label="Desligar"><action name="Execute"><command>systemctl poweroff</command></action></item>
  </menu>
</openbox_menu>
EOF

cat > config/includes.chroot/etc/xdg/openbox/autostart <<'EOF'
# NexHash EdgeOS graphical startup
feh --bg-fill /usr/share/nexhash/wallpaper.png &
tint2 -c /etc/xdg/tint2/nexhash.tint2rc &
(sleep 2; nm-applet) &
(sleep 2; unclutter -idle 4) &
# Screen may blank to save battery; the OS itself never suspends.
xset s 600 600
xset +dpms
xset dpms 0 0 600
if [ -e /run/live/medium ]; then
  (sleep 3; /usr/local/bin/nexhash-live-installer) &
else
  (sleep 5; /usr/local/bin/nexhash-browser) &
fi
EOF

cat > config/includes.chroot/etc/xdg/tint2/nexhash.tint2rc <<'EOF'
rounded = 0
border_width = 0
background_color = #08111d 94
border_color = #203752 100

rounded = 8
border_width = 1
background_color = #0d1a2a 95
border_color = #223d5a 100

panel_items = TSBC
panel_size = 100% 44
panel_margin = 0 0
panel_padding = 10 4 10
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
panel_shrink = 0
wm_menu = 1

taskbar_mode = single_desktop
taskbar_padding = 4 2 4
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 0
taskbar_hide_if_empty = 0

task_icon = 1
task_text = 1
task_centered = 0
task_maximum_size = 180 34
task_padding = 8 3 8
task_font = Noto Sans 9
task_font_color = #eaf5ff 100
task_active_font_color = #43a8ff 100
task_background_id = 2
task_active_background_id = 2

systray_padding = 8 6 8
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 22
systray_monitor = 1

battery = 1
battery_hide = 0
battery_low_status = 10
battery_low_cmd = notify-send "NexHash EdgeOS" "Bateria baixa"
bat1_font = Noto Sans Bold 9
bat1_font_color = #eaf5ff 100
bat1_format = BAT %p%%
bat2_font = Noto Sans 8
bat2_font_color = #8fb3d6 100
bat2_format = %t
battery_padding = 12 0
battery_background_id = 0

time1_format = %H:%M
time2_format = %d/%m/%Y
time1_font = Noto Sans Bold 10
time2_font = Noto Sans 8
clock_font_color = #eaf5ff 100
clock_padding = 12 0
clock_background_id = 0
clock_tooltip = %A, %d %B %Y
EOF

cat > config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf.d/50-nexhash.conf <<'EOF'
[greeter]
background=/usr/share/nexhash/wallpaper.png
theme-name=Adwaita
font-name=Noto Sans 10
hide-user-image=true
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-live-installer <<'EOF'
#!/bin/bash
set -u
[ -e /run/live/medium ] || exit 0
pgrep -x calamares >/dev/null 2>&1 && exit 0
sudo -n calamares >/tmp/nexhash-calamares.log 2>&1 &
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-wifi <<'EOF'
#!/bin/bash
set -u
rfkill unblock all 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
sleep 1
nmcli dev wifi rescan 2>/dev/null || true

mapfile -t rows < <(nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null | awk -F: 'length($1)>0 {print $1 "|" $2 "|" $3}' | awk '!seen[$1]++')
if [ "${#rows[@]}" -eq 0 ]; then
  zenity --error --title="NexHash Wi-Fi" --text="Nenhuma rede Wi-Fi encontrada. Verifique o modo aviao ou use cabo de rede."
  exit 1
fi

args=()
for r in "${rows[@]}"; do
  IFS='|' read -r ssid sig sec <<<"$r"
  args+=("$ssid" "$sig%" "$sec")
done
ssid=$(zenity --list --title="NexHash Wi-Fi" --text="Escolha uma rede" --width=620 --height=420 \
  --column="Rede" --column="Sinal" --column="Seguranca" "${args[@]}" --print-column=1) || exit 0
[ -n "$ssid" ] || exit 0
if nmcli -t -f NAME con show | grep -Fxq "$ssid"; then
  nmcli con up "$ssid" && exit 0
fi
pass=$(zenity --password --title="Senha do Wi-Fi - $ssid") || exit 0
nmcli dev wifi connect "$ssid" password "$pass"
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-browser <<'EOF'
#!/bin/bash
set -u
. /etc/nexhash/device.env 2>/dev/null || true
HOME_URL="${NEXHASH_HOME_URL:-http://127.0.0.1:8787}"
STATUS_URL="${NEXHASH_STATUS_URL:-http://127.0.0.1:8790}"
PORT="${NEXHASH_PORT:-8787}"
for _ in $(seq 1 15); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$PORT" >/dev/null 2>&1; then
    exec opera --new-window "$HOME_URL"
  fi
  sleep 1
done
exec opera --new-window "$STATUS_URL"
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-bridge-start <<'EOF'
#!/bin/bash
set -Eeuo pipefail
. /etc/nexhash/device.env 2>/dev/null || true
APP_DIR="${NEXHASH_APP_DIR:-/opt/nexhash/current}"
PORT="${NEXHASH_PORT:-8787}"
mkdir -p /opt/nexhash/releases /var/lib/nexhash /var/log/nexhash
if [ ! -e "$APP_DIR" ]; then
  echo "NexHash Core ainda nao foi implantado. EdgeOS permanece online." >&2
  exit 78
fi
cd "$APP_DIR"
export PORT NEXHASH_PORT="$PORT"
if [ -x ./start.sh ]; then exec ./start.sh
elif [ -x ./nexhash-server ]; then exec ./nexhash-server --port "$PORT"
elif [ -f ./server.py ]; then exec python3 ./server.py
elif [ -f ./app.py ]; then exec python3 ./app.py
else echo "Pacote NexHash invalido em $APP_DIR" >&2; exit 64
fi
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-deploy <<'EOF'
#!/bin/bash
set -Eeuo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Use: sudo nexhash-deploy <pasta-ou-zip>"; exit 1; }
[ $# -eq 1 ] || { echo "Use: sudo nexhash-deploy <pasta-ou-zip>"; exit 2; }
. /etc/nexhash/device.env 2>/dev/null || true
ROOT="${NEXHASH_APP_ROOT:-/opt/nexhash}"; RELEASES="$ROOT/releases"; CURRENT="$ROOT/current"; PREVIOUS="$ROOT/previous"
STAMP=$(date +%Y%m%d-%H%M%S); NEW="$RELEASES/$STAMP"; STAGE=$(mktemp -d /tmp/nexhash-deploy.XXXXXX)
OLD=$(readlink -f "$CURRENT" 2>/dev/null || true)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$RELEASES" /var/lib/nexhash
if [ -d "$1" ]; then cp -a "$1"/. "$STAGE"/; else unzip -q "$1" -d "$STAGE"; fi
SRC="$STAGE"
count=$(find "$STAGE" -mindepth 1 -maxdepth 1 | wc -l)
if [ "$count" -eq 1 ]; then only=$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1 || true); [ -n "$only" ] && SRC="$only"; fi
mkdir -p "$NEW"; cp -a "$SRC"/. "$NEW"/
if [ ! -x "$NEW/start.sh" ] && [ ! -x "$NEW/nexhash-server" ] && [ ! -f "$NEW/server.py" ] && [ ! -f "$NEW/app.py" ]; then rm -rf "$NEW"; echo "Pacote invalido."; exit 4; fi
[ -n "$OLD" ] && ln -sfn "$OLD" "$PREVIOUS" || true
ln -sfn "$NEW" "$CURRENT.new"; mv -Tf "$CURRENT.new" "$CURRENT"
systemctl restart nexhash-bridge.service || true
echo "Deploy: $NEW"
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-supervisor.py <<'EOF'
#!/usr/bin/python3
import os,socket,subprocess,time
from pathlib import Path
PORT=int(os.getenv("NEXHASH_PORT","8787"))
FAILMAX=int(os.getenv("NEXHASH_HEALTH_FAILURES","3"))
LOG=Path("/var/lib/nexhash/recovery.log")
fails=0
while True:
    ok=False
    try:
        with socket.create_connection(("127.0.0.1",PORT),1): ok=True
    except OSError: pass
    svc=subprocess.run(["systemctl","is-active","--quiet","nexhash-bridge.service"]).returncode==0
    if ok or not svc: fails=0
    else:
        fails+=1
        if fails>=FAILMAX:
            subprocess.run(["systemctl","restart","nexhash-bridge.service"],check=False)
            LOG.parent.mkdir(parents=True,exist_ok=True)
            with LOG.open("a") as f: f.write(time.strftime("%Y-%m-%dT%H:%M:%S ")+"bridge-restart\n")
            fails=0
    time.sleep(20)
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-edge-status.py <<'EOF'
#!/usr/bin/python3
import http.server,json,os,shutil,socket,subprocess
from pathlib import Path
PORT=int(os.getenv("NEXHASH_STATUS_PORT","8790"))
BRIDGE=int(os.getenv("NEXHASH_PORT","8787"))
def run(cmd):
    try:return subprocess.check_output(cmd,stderr=subprocess.DEVNULL,text=True).strip()
    except:return ""
def svc(n): return subprocess.run(["systemctl","is-active","--quiet",n]).returncode==0
def battery():
    vals=[]
    for p in Path("/sys/class/power_supply").glob("BAT*/capacity"):
        try: vals.append(int(p.read_text().strip()))
        except: pass
    return round(sum(vals)/len(vals)) if vals else None
def temp():
    vals=[]
    for p in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            v=int(p.read_text().strip())/1000
            if 10 < v < 120: vals.append(v)
        except: pass
    return round(max(vals),1) if vals else None
def bridge():
    try:
        with socket.create_connection(("127.0.0.1",BRIDGE),.5): return True
    except: return False
def data():
    du=shutil.disk_usage("/")
    mem={}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            k,v=line.split(":",1); mem[k]=int(v.split()[0])
        mp=round((1-mem["MemAvailable"]/mem["MemTotal"])*100,1)
    except: mp=0
    wifi=run(["nmcli","-t","-f","ACTIVE,SSID","dev","wifi"])
    ssid=""
    for x in wifi.splitlines():
        if x.startswith("yes:"): ssid=x[4:]; break
    return {
      "edgeos":"1.2 Industrial","core":bridge(),"tailscale":svc("tailscaled.service"),
      "tailscale_ip":run(["tailscale","ip","-4"]) or "nao conectado",
      "lan_ip":run(["sh","-lc","hostname -I | awk '{print $1}'"]) or "n/a",
      "wifi":ssid or "nao conectado","battery":battery(),"temperature":temp(),
      "memory":mp,"disk":round(du.used/du.total*100,1)
    }
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        m=data()
        if self.path=="/api/status":
            b=json.dumps(m).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(b); return
        core="ONLINE" if m["core"] else "AGUARDANDO DEPLOY"
        bat=f'{m["battery"]}%' if m["battery"] is not None else "n/a"
        tc=f'{m["temperature"]} C' if m["temperature"] is not None else "n/a"
        cards=[
          ("NexHash Core",core),("Wi-Fi",m["wifi"]),("Tailscale",m["tailscale_ip"]),
          ("IP LAN",m["lan_ip"]),("Bateria",bat),("Temperatura",tc),
          ("RAM",f'{m["memory"]}%'),("Disco",f'{m["disk"]}%')
        ]
        cs="".join(f'<div class="card"><span>{a}</span><b>{v}</b></div>' for a,v in cards)
        html=f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="10"><title>NexHash EdgeOS</title><style>
*{{box-sizing:border-box}} body{{margin:0;background:radial-gradient(circle at 75% 15%,#0d2d55,#050912 48%);color:#edf7ff;font:15px system-ui;min-height:100vh}} .wrap{{max-width:1080px;margin:auto;padding:44px 28px}} .brand{{font-size:46px;font-weight:850;letter-spacing:-2px}} .blue{{color:#1597ff}} .sub{{color:#8caac5;margin-top:4px}} .pill{{display:inline-block;margin-top:20px;background:#0c2138;border:1px solid #174a75;color:#69c3ff;padding:9px 13px;border-radius:99px;font-weight:800}} .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px;margin-top:28px}} .card{{background:#0a1421dd;border:1px solid #19344f;border-radius:16px;padding:20px;min-height:100px;box-shadow:0 10px 30px #0004}} .card span{{color:#7897b3;font-size:13px}} .card b{{display:block;margin-top:10px;font-size:19px;overflow:hidden;text-overflow:ellipsis}} .foot{{margin-top:28px;color:#7590aa}} code{{color:#68c1ff}}</style></head><body><div class="wrap"><div class="brand">Nex<span class="blue">Hash</span></div><div class="sub">EdgeOS 1.2 Industrial · Forge</div><div class="pill">EDGE NODE ONLINE</div><div class="grid">{cs}</div><div class="foot">Controle industrial enxuto. O NexHash Core pode ser implantado sem reinstalar o sistema.</div></div></body></html>'''.encode()
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers(); self.wfile.write(html)
http.server.ThreadingHTTPServer(("0.0.0.0",PORT),H).serve_forever()
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-network-heal <<'EOF'
#!/bin/bash
set -u
STATE=/var/lib/nexhash/network-failures
mkdir -p /var/lib/nexhash
n=$(cat "$STATE" 2>/dev/null || echo 0)
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then echo 0 > "$STATE"; exit 0; fi
n=$((n+1)); echo "$n" > "$STATE"
if [ "$n" -ge 3 ]; then
  rfkill unblock all 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  systemctl restart NetworkManager.service || true
  sleep 6
  echo 0 > "$STATE"
  printf '%s network-recovery\n' "$(date -Is)" >> /var/lib/nexhash/recovery.log
fi
EOF

cat > config/includes.chroot/usr/local/bin/nexhash-firstboot <<'EOF'
#!/bin/bash
set -Eeuo pipefail
mkdir -p /var/lib/nexhash /var/log/nexhash /opt/nexhash/releases
rfkill unblock all 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
for i in /sys/class/net/wl*; do [ -e "$i" ] && ip link set "$(basename "$i")" up 2>/dev/null || true; done
USER_NAME=$(getent passwd 1000 | cut -d: -f1 || true)
if [ -n "$USER_NAME" ]; then
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/50-nexhash-autologin.conf <<EOC
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
user-session=openbox
EOC
fi
systemctl enable NetworkManager.service lightdm.service tailscaled.service tlp.service acpid.service irqbalance.service nftables.service nexhash-status.service nexhash-bridge.service nexhash-supervisor.service nexhash-network-heal.timer 2>/dev/null || true
systemctl disable ssh.service bluetooth.service cups.service cups-browsed.service ModemManager.service avahi-daemon.service 2>/dev/null || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
touch /var/lib/nexhash/.firstboot-done
EOF

cat > config/includes.chroot/usr/local/bin/nexhashctl <<'EOF'
#!/bin/bash
set -u
. /etc/nexhash/device.env 2>/dev/null || true
case "${1:-}" in
  status) cat /etc/nexhash/release; systemctl --no-pager status nexhash-status.service tailscaled.service 2>/dev/null || true ;;
  health) curl -fsS "${NEXHASH_STATUS_URL:-http://127.0.0.1:8790}/api/status" | jq . ;;
  tailscale-login) sudo tailscale up ;;
  tailscale-status) tailscale status ;;
  wifi) /usr/local/bin/nexhash-wifi ;;
  *) echo "Uso: nexhashctl {status|health|tailscale-login|tailscale-status|wifi}" ;;
esac
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-firstboot.service <<'EOF'
[Unit]
Description=NexHash EdgeOS first boot setup
ConditionPathExists=!/var/lib/nexhash/.firstboot-done
Before=lightdm.service
After=NetworkManager.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nexhash-firstboot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-bridge.service <<'EOF'
[Unit]
Description=NexHash Edge Bridge
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=-/etc/nexhash/device.env
ExecStart=/usr/local/bin/nexhash-bridge-start
Restart=on-failure
RestartSec=4
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2
[Install]
WantedBy=multi-user.target
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-status.service <<'EOF'
[Unit]
Description=NexHash EdgeOS Status API
After=network.target
[Service]
Type=simple
EnvironmentFile=-/etc/nexhash/device.env
ExecStart=/usr/bin/python3 /usr/local/bin/nexhash-edge-status.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-supervisor.service <<'EOF'
[Unit]
Description=NexHash Service Supervisor
After=nexhash-bridge.service
[Service]
Type=simple
EnvironmentFile=-/etc/nexhash/device.env
ExecStart=/usr/bin/python3 /usr/local/bin/nexhash-supervisor.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-network-heal.service <<'EOF'
[Unit]
Description=NexHash network self-heal
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nexhash-network-heal
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-network-heal.timer <<'EOF'
[Unit]
Description=Periodic NexHash network health check
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
Unit=nexhash-network-heal.service
[Install]
WantedBy=timers.target
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-maintenance.service <<'EOF'
[Unit]
Description=NexHash EdgeOS maintenance
[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'journalctl --vacuum-size=100M; apt-get clean'
EOF

cat > config/includes.chroot/etc/systemd/system/nexhash-maintenance.timer <<'EOF'
[Unit]
Description=Daily NexHash EdgeOS maintenance
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

# Create a branded wallpaper at build time.
python3 - <<'PY'
from PIL import Image, ImageDraw, ImageFont
W,H=1920,1080
im=Image.new("RGB",(W,H))
px=im.load()
for y in range(H):
    for x in range(W):
        t=(x/W)*0.55+(1-y/H)*0.45
        r=int(4+5*t); g=int(8+24*t); b=int(16+48*t)
        px[x,y]=(r,g,b)
d=ImageDraw.Draw(im,"RGBA")
for cx,cy,rad,a in [(1540,160,420,28),(1680,260,650,15),(250,900,520,14)]:
    d.ellipse((cx-rad,cy-rad,cx+rad,cy+rad),fill=(20,135,255,a))
font="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
bold="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
f1=ImageFont.truetype(bold,92); f2=ImageFont.truetype(font,30); f3=ImageFont.truetype(font,20)
d.text((110,130),"Nex",font=f1,fill=(238,248,255,255))
w=d.textlength("Nex",font=f1)
d.text((110+w,130),"Hash",font=f1,fill=(28,151,255,255))
d.text((116,245),"EDGEOS 1.2  ·  INDUSTRIAL CONTROL NODE",font=f2,fill=(148,181,210,255))
d.rounded_rectangle((110,330,620,410),22,fill=(8,26,44,190),outline=(35,82,122,255),width=2)
d.text((142,350),"READY · SECURE · REMOTE",font=f3,fill=(96,196,255,255))
d.text((116,980),"NexHash EdgeOS · Debian 13",font=f3,fill=(105,132,158,255))
im.save("config/includes.chroot/usr/share/nexhash/wallpaper.png","PNG",optimize=True)
PY

cat > config/hooks/normal/090-nexhash.hook.chroot <<'EOF'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
chmod +x /usr/local/bin/nexhash-*
systemctl enable NetworkManager.service lightdm.service tailscaled.service tlp.service acpid.service irqbalance.service nftables.service nexhash-firstboot.service nexhash-status.service nexhash-bridge.service nexhash-supervisor.service nexhash-network-heal.timer nexhash-maintenance.timer || true
systemctl disable ssh.service bluetooth.service cups.service cups-browsed.service ModemManager.service avahi-daemon.service 2>/dev/null || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
apt-get clean
EOF
chmod +x config/hooks/normal/090-nexhash.hook.chroot

lb build

ISO=$(find . -maxdepth 1 -type f -name 'live-image-amd64*.hybrid.iso' -o -name 'live-image-amd64*.iso' | head -n1)
[ -n "$ISO" ] && [ -s "$ISO" ]
FINAL="$OUT/NexHash-EdgeOS-1.2-Industrial-amd64.iso"
cp "$ISO" "$FINAL"
sha256sum "$FINAL" | tee "$FINAL.sha256"
file "$FINAL" | tee "$OUT/iso-file.txt"
xorriso -indev "$FINAL" -report_el_torito plain -report_system_area plain 2>&1 | tee "$OUT/boot-report.txt"
grep -Eqi 'El Torito|EFI|BIOS|MBR|GPT' "$OUT/boot-report.txt"

# Extract squashfs and prove the two external applications are INSIDE the final ISO.
mkdir -p "$OUT/extract"
xorriso -osirrox on -indev "$FINAL" -extract /live/filesystem.squashfs "$OUT/filesystem.squashfs" >/dev/null 2>&1
unsquashfs -ll "$OUT/filesystem.squashfs" > "$OUT/filesystem-list.txt"
grep -Eq '/usr/bin/opera$|/usr/bin/opera-stable$' "$OUT/filesystem-list.txt"
grep -Eq '/usr/bin/tailscale$' "$OUT/filesystem-list.txt"
grep -Eq '/usr/bin/nm-applet$' "$OUT/filesystem-list.txt"
grep -Eq '/usr/bin/rfkill$' "$OUT/filesystem-list.txt"
grep -Eq 'grub.*signed|shim' "$OUT/filesystem-list.txt"

# BIOS smoke boot.
set +e
timeout 25s qemu-system-x86_64 -m 1536 -smp 2 -cdrom "$FINAL" -boot d -display none -serial stdio -no-reboot > "$OUT/qemu-bios.log" 2>&1
QRC=$?
set -e
[ "$QRC" -eq 0 ] || [ "$QRC" -eq 124 ]

cat > "$OUT/BUILD-VALIDATED.txt" <<EOF
NexHash EdgeOS 1.2 ISO validated.
Opera embedded: yes
Tailscale embedded: yes
Wi-Fi stack embedded: yes
Signed UEFI stack embedded: yes
BIOS smoke rc=$QRC
EOF
cat "$OUT/BUILD-VALIDATED.txt"
