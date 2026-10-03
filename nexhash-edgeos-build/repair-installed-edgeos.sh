#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== NexHash EdgeOS Installed-System Repair ==="
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Execute com sudo."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Verificando internet..."
if ! getent hosts deb.opera.com >/dev/null 2>&1; then
  echo "ERRO: sem internet/DNS. Conecte o Wi-Fi e rode novamente."
  exit 10
fi

echo "[2/6] Instalando chaves/repositorios..."
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://deb.opera.com/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/opera-browser.gpg
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/opera-browser.gpg] https://deb.opera.com/opera-stable/ stable non-free' > /etc/apt/sources.list.d/opera-stable.list

curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list

echo "[3/6] Instalando Opera e Tailscale..."
apt-get update
apt-get install -y --no-install-recommends opera-stable tailscale

echo "[4/6] Garantindo comando opera..."
if ! command -v opera >/dev/null 2>&1; then
  CANDIDATE="$(dpkg -L opera-stable 2>/dev/null | awk '/\/opera$/ && $0 !~ /resources/ {print; exit}')"
  if [[ -n "$CANDIDATE" && -x "$CANDIDATE" ]]; then
    ln -sf "$CANDIDATE" /usr/local/bin/opera
  fi
fi
command -v opera >/dev/null 2>&1 || { echo "ERRO: Opera instalado mas executavel nao localizado."; dpkg -L opera-stable | tail -n 80; exit 20; }

echo "[5/6] Ativando servicos NexHash/Tailscale..."
systemctl enable --now tailscaled.service
for s in nexhash-status.service nexhash-bridge.service nexhash-supervisor.service nexhash-network-heal.timer nexhash-maintenance.timer; do
  systemctl enable --now "$s" 2>/dev/null || true
done

echo "[6/6] Corrigindo autostart grafico..."
install -d -m 0755 /etc/xdg/openbox
if [[ -f /etc/xdg/openbox/autostart ]]; then
  cp -a /etc/xdg/openbox/autostart "/etc/xdg/openbox/autostart.bak.$(date +%s)"
fi
cat > /etc/xdg/openbox/autostart <<'EOF'
# NexHash EdgeOS autostart
(sleep 2; nm-applet) &
(sleep 4; /usr/local/bin/nexhash-browser) &
EOF

# Desktop menu: prefer the stable wrapper.
if [[ -f /etc/xdg/openbox/menu.xml ]]; then
  sed -i 's#<command>opera http://127.0.0.1:8787</command>#<command>/usr/local/bin/nexhash-browser</command>#g' /etc/xdg/openbox/menu.xml
  sed -i 's#<command>opera</command>#<command>opera</command>#g' /etc/xdg/openbox/menu.xml
fi

echo
echo "Opera: $(command -v opera)"
opera --version 2>/dev/null || true
tailscale version 2>/dev/null | head -n1 || true
echo
echo "REPAIR_OK"
echo "Reinicie o notebook. O Opera deve abrir automaticamente."
