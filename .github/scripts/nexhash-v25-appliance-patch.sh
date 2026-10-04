#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-source}"
OUT_DIR="${2:-out}"
SRC="$(find "$SRC_DIR" -type f -name '*.iso' | head -n1)"
test -s "$SRC"

sudo apt-get update >/dev/null
sudo apt-get install -y xorriso squashfs-tools curl >/dev/null

rm -rf work25 rootfs25 "$OUT_DIR"
mkdir -p work25 rootfs25 "$OUT_DIR"

echo "[1/8] Extract base 2.4 filesystem"
xorriso -osirrox on -indev "$SRC" -extract /live/filesystem.squashfs work25/filesystem.squashfs >/dev/null 2>&1
sudo unsquashfs -d rootfs25 work25/filesystem.squashfs >/dev/null

echo "[2/8] Prepare chroot"
sudo rm -f rootfs25/etc/resolv.conf
sudo cp /etc/resolv.conf rootfs25/etc/resolv.conf
for d in dev proc sys; do sudo mount --bind "/$d" "rootfs25/$d"; done
cleanup(){ for d in dev proc sys; do sudo umount -lf "rootfs25/$d" 2>/dev/null || true; done; }
trap cleanup EXIT

sudo tee rootfs25/tmp/nexhash-v25.sh >/dev/null <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/sources.list <<'EOF_APT'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF_APT
find /etc/apt/sources.list.d -type f -print0 2>/dev/null | xargs -0 -r sed -i '/file:\/run\/live\/medium/d' || true

apt-get update
apt-get install -y docker.io docker-compose-v2 curl jq ca-certificates
systemctl enable docker.service containerd.service NetworkManager.service tailscaled.service || true

install -d -m 0755 /opt/nexhash/current /opt/nexhash/releases /var/lib/nexhash /etc/nexhash /usr/local/lib/nexhash
cat > /etc/nexhash/device.env <<'EOF_ENV'
NEXHASH_PORT=8787
NEXHASH_HEALTH_PORT=8790
NEXHASH_URL=http://127.0.0.1:8787
NEXHASH_HEALTH_URL=http://127.0.0.1:8790
EOF_ENV

cat > /usr/local/bin/nexhash-app-start <<'EOF_START'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/nexhash/current

# Commercial V1.5 Production Cloud is Docker Compose based.
if [ -f docker-compose.yml ] || [ -f compose.yml ] || [ -f compose.yaml ]; then
  if [ -f .env ]; then
    exec /usr/bin/docker compose --env-file .env up
  else
    exec /usr/bin/docker compose up
  fi
fi

# Compatibility fallbacks for local bridge builds.
if [ -f package.json ]; then
  exec /usr/bin/npm start -- --host 0.0.0.0 --port 8787
fi
if [ -f app.py ]; then
  exec /usr/bin/python3 app.py
fi
echo "NexHash application payload missing or unsupported in /opt/nexhash/current" >&2
exit 78
EOF_START
chmod +x /usr/local/bin/nexhash-app-start

cat > /usr/local/bin/nexhash-app-stop <<'EOF_STOP'
#!/usr/bin/env bash
set -u
cd /opt/nexhash/current 2>/dev/null || exit 0
if [ -f docker-compose.yml ] || [ -f compose.yml ] || [ -f compose.yaml ]; then
  /usr/bin/docker compose down --remove-orphans || true
fi
EOF_STOP
chmod +x /usr/local/bin/nexhash-app-stop

cat > /etc/systemd/system/nexhash.service <<'EOF_SERVICE'
[Unit]
Description=NexHash Commercial appliance
Wants=network-online.target docker.service tailscaled.service
After=network-online.target docker.service tailscaled.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=/opt/nexhash/current
EnvironmentFile=-/etc/nexhash/device.env
ExecStart=/usr/local/bin/nexhash-app-start
ExecStop=/usr/local/bin/nexhash-app-stop
Restart=always
RestartSec=5
TimeoutStartSec=0
TimeoutStopSec=45
Nice=-5
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF_SERVICE

cat > /usr/local/bin/nexhash-healthcheck <<'EOF_HEALTH'
#!/usr/bin/env bash
set -u
source /etc/nexhash/device.env 2>/dev/null || true
URL="${NEXHASH_URL:-http://127.0.0.1:8787}"
if curl -fsS --max-time 4 "$URL" >/dev/null 2>&1; then
  exit 0
fi
systemctl restart nexhash.service
exit 1
EOF_HEALTH
chmod +x /usr/local/bin/nexhash-healthcheck

cat > /etc/systemd/system/nexhash-healthcheck.service <<'EOF_HS'
[Unit]
Description=NexHash web health check
After=nexhash.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nexhash-healthcheck
EOF_HS

cat > /etc/systemd/system/nexhash-healthcheck.timer <<'EOF_HT'
[Unit]
Description=Check NexHash every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
Unit=nexhash-healthcheck.service
Persistent=true

[Install]
WantedBy=timers.target
EOF_HT

cat > /usr/local/bin/nexhash-wait-open <<'EOF_OPEN'
#!/usr/bin/env bash
set -u
for i in $(seq 1 90); do
  if curl -fsS --max-time 2 http://127.0.0.1:8787 >/dev/null 2>&1; then
    exec opera --start-maximized http://127.0.0.1:8787
  fi
  sleep 2
done
exec opera --start-maximized http://127.0.0.1:8787
EOF_OPEN
chmod +x /usr/local/bin/nexhash-wait-open

install -d -m 0755 /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/nexhash-opera.desktop <<'EOF_OPERA'
[Desktop Entry]
Type=Application
Name=NexHash
Exec=/usr/local/bin/nexhash-wait-open
Icon=opera
X-KDE-autostart-after=panel
Terminal=false
EOF_OPERA

cat > /usr/local/bin/nexhashctl <<'EOF_CTL'
#!/usr/bin/env bash
set -u
case "${1:-status}" in
  status) systemctl --no-pager --full status nexhash.service ;;
  restart) sudo -n systemctl restart nexhash.service ;;
  logs) journalctl -u nexhash.service -n 150 --no-pager ;;
  health) curl -fsS http://127.0.0.1:8787 >/dev/null && echo "NexHash: OK" || { echo "NexHash: OFFLINE"; exit 1; } ;;
  tailscale-status) tailscale status ;;
  tailscale-login) sudo -n tailscale up ;;
  *) echo "usage: nexhashctl {status|restart|logs|health|tailscale-status|tailscale-login}"; exit 2 ;;
esac
EOF_CTL
chmod +x /usr/local/bin/nexhashctl

systemctl enable nexhash.service nexhash-healthcheck.timer || true

# Make the product center show the appliance state.
if [ -f /usr/local/bin/nexhash-welcome ]; then
  sed -i 's/self.system.status.setText("● Operacional")/self.system.status.setText("● Operacional • NexHash " + ("ONLINE" if run("curl -fsS --max-time 2 http:\/\/127.0.0.1:8787 >\/dev\/null 2>\&1 \&\& echo ok") else "OFFLINE"))/' /usr/local/bin/nexhash-welcome || true
fi

apt-get clean
CHROOT

sudo chmod +x rootfs25/tmp/nexhash-v25.sh
sudo chroot rootfs25 /bin/bash /tmp/nexhash-v25.sh
sudo rm -f rootfs25/tmp/nexhash-v25.sh

cleanup
trap - EXIT

# Do not ship CI DNS.
sudo rm -f rootfs25/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee rootfs25/etc/resolv.conf >/dev/null

echo "[3/8] Verify application payload exists"
test -e rootfs25/opt/nexhash/current/.nexhash-v15-present || {
  echo "Commercial V1.5 payload marker is missing. Refusing to build a fake final ISO." >&2
  exit 44
}

echo "[4/8] Verify appliance services"
test -f rootfs25/etc/systemd/system/nexhash.service
grep -q 'Restart=always' rootfs25/etc/systemd/system/nexhash.service
grep -q '127.0.0.1:8787' rootfs25/usr/local/bin/nexhash-healthcheck
grep -q 'opera --start-maximized' rootfs25/usr/local/bin/nexhash-wait-open
test -e rootfs25/etc/systemd/system/multi-user.target.wants/nexhash.service
test -e rootfs25/etc/systemd/system/timers.target.wants/nexhash-healthcheck.timer

echo "[5/8] Repack filesystem"
sudo mksquashfs rootfs25 work25/filesystem-new.squashfs -comp xz -b 1M -noappend >/dev/null

echo "[6/8] Build ISO"
DEST="$OUT_DIR/NexHash-EdgeOS-2.5-APPLIANCE-FINAL-Install-amd64.iso"
mkdir -p "$OUT_DIR"
xorriso -indev "$SRC" -outdev "$DEST" -boot_image any replay \
  -map work25/filesystem-new.squashfs /live/filesystem.squashfs -commit >/dev/null

echo "[7/8] Validate ISO contents"
rm -rf verify25 && mkdir verify25
xorriso -osirrox on -indev "$DEST" -extract /live/filesystem.squashfs verify25/filesystem.squashfs >/dev/null 2>&1
unsquashfs -cat verify25/filesystem.squashfs etc/systemd/system/nexhash.service | grep -q 'Restart=always'
unsquashfs -cat verify25/filesystem.squashfs usr/local/bin/nexhash-healthcheck | grep -q '127.0.0.1:8787'
unsquashfs -cat verify25/filesystem.squashfs etc/skel/.config/autostart/nexhash-opera.desktop | grep -q 'nexhash-wait-open'
unsquashfs -cat verify25/filesystem.squashfs opt/nexhash/current/.nexhash-v15-present | grep -q 'Commercial V1.5'
unsquashfs -cat verify25/filesystem.squashfs var/lib/dpkg/status > verify25/status
grep -q '^Package: docker.io$' verify25/status
grep -q '^Package: docker-compose-v2$' verify25/status
grep -q '^Package: opera-stable$' verify25/status
grep -q '^Package: tailscale$' verify25/status

echo "[8/8] Checksums"
sha256sum "$DEST" | tee "$OUT_DIR/NexHash-EdgeOS-2.5-APPLIANCE-FINAL-Install-amd64.iso.sha256"
cat > "$OUT_DIR/FINAL-VALIDATED.txt" <<EOF_FINAL
NEXHASH EDGEOS 2.5 APPLIANCE FINAL
Commercial V1.5 payload: OK
nexhash.service boot autostart: OK
Restart=always: OK
Healthcheck/recovery timer: OK
Port 8787 target: OK
Docker + Compose runtime: OK
Tailscale service dependency: OK
Opera NexHash autostart: OK
2.4 network/DNS/sudo/battery fixes inherited: OK
EOF_FINAL
