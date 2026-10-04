#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-/}"

install -d -m 0755   "$ROOT/opt/nexhash/current"   "$ROOT/opt/nexhash/releases"   "$ROOT/etc/nexhash"   "$ROOT/var/lib/nexhash"   "$ROOT/var/log/nexhash"   "$ROOT/usr/local/lib/nexhash"   "$ROOT/etc/systemd/system"   "$ROOT/usr/local/bin"

cat > "$ROOT/etc/nexhash/device.env" <<'EOF'
NEXHASH_PORT=8787
NEXHASH_HEALTH_PORT=8790
NEXHASH_BIND=0.0.0.0
ASIC_WATCHDOG_ENABLED=1
ASIC_POLL_SECONDS=20
ASIC_FAILURE_CONFIRMATIONS=3
ASIC_COOLDOWN_SECONDS=180
ASIC_STABILIZE_SECONDS=240
ASIC_MAX_RETRIES=3
ASIC_RETRY_BACKOFF_SECONDS=300
ASIC_MIN_HASHRATE_RATIO=0.20
ASIC_TARGET_TEMP_C=70
ASIC_MAX_TEMP_C=82
EOF

cat > "$ROOT/usr/local/bin/nexhash-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/nexhash/current
export PORT="${NEXHASH_PORT:-8787}"
export HOST="${NEXHASH_BIND:-0.0.0.0}"

if [ -x ./run.sh ]; then exec ./run.sh; fi
if [ -f package.json ]; then
  if [ -f package-lock.json ]; then npm ci --omit=dev || npm install; else npm install; fi
  if node -e 'let p=require("./package.json");process.exit(p.scripts&&p.scripts.start?0:1)'; then
    exec npm start -- --hostname "$HOST" --port "$PORT"
  fi
fi
if [ -f requirements.txt ]; then pip3 install --break-system-packages -r requirements.txt; fi
if [ -f app.py ]; then exec python3 app.py; fi
if [ -f server.py ]; then exec python3 server.py; fi
if [ -f main.py ]; then exec python3 main.py; fi

echo "NexHash application not found in /opt/nexhash/current" >&2
exit 78
EOF
chmod +x "$ROOT/usr/local/bin/nexhash-run"

cat > "$ROOT/etc/systemd/system/nexhash.service" <<'EOF'
[Unit]
Description=NexHash ASIC Management Server
After=network-online.target tailscaled.service
Wants=network-online.target
RequiresMountsFor=/opt/nexhash

[Service]
Type=simple
EnvironmentFile=-/etc/nexhash/device.env
WorkingDirectory=/opt/nexhash/current
ExecStart=/usr/local/bin/nexhash-run
Restart=always
RestartSec=5
StartLimitIntervalSec=0
TimeoutStartSec=180
TimeoutStopSec=30
KillSignal=SIGINT
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/nexhash /var/lib/nexhash /var/log/nexhash /tmp
OOMScoreAdjust=-500
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOT/usr/local/lib/nexhash/asic_watchdog.py" <<'PY'
#!/usr/bin/env python3
import json, os, socket, subprocess, time, urllib.request, urllib.error
from pathlib import Path
from datetime import datetime, timezone

STATE=Path("/var/lib/nexhash/asic-watchdog.json")
LOG=Path("/var/log/nexhash/asic-watchdog.log")
CFG=Path("/etc/nexhash/miners.json")

POLL=int(os.getenv("ASIC_POLL_SECONDS","20"))
FAIL_CONFIRM=int(os.getenv("ASIC_FAILURE_CONFIRMATIONS","3"))
COOLDOWN=int(os.getenv("ASIC_COOLDOWN_SECONDS","180"))
STABILIZE=int(os.getenv("ASIC_STABILIZE_SECONDS","240"))
MAX_RETRIES=int(os.getenv("ASIC_MAX_RETRIES","3"))
BACKOFF=int(os.getenv("ASIC_RETRY_BACKOFF_SECONDS","300"))
MIN_RATIO=float(os.getenv("ASIC_MIN_HASHRATE_RATIO","0.20"))

def log(msg, miner=None):
    ts=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    line=f"{ts} " + (f"[{miner}] " if miner else "") + msg
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a",encoding="utf-8") as f: f.write(line+"\n")

def load_json(p, default):
    try: return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception: return default

def save_state(s):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp=STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(s,indent=2),encoding="utf-8")
    tmp.replace(STATE)

def tcp(ip,port,timeout=2):
    try:
        with socket.create_connection((ip,port),timeout=timeout): return True
    except OSError: return False

def http_json(url,timeout=3):
    try:
        with urllib.request.urlopen(url,timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8","ignore"))
    except Exception: return None

def detect_hashrate(m):
    ip=m["ip"]
    # Optional NexHash/Braiins-compatible metrics endpoint configured per miner.
    for url in [m.get("status_url"),f"http://{ip}/api/v1/status",f"http://{ip}/api/status"]:
        if not url: continue
        data=http_json(url)
        if isinstance(data,dict):
            for key in ("hashrate","hash_rate","hashrate_ths","ghs_5s","rate_5s"):
                v=data.get(key)
                if isinstance(v,(int,float)): return float(v)
    return None

def run_action(m, action):
    cmds=m.get("commands",{})
    cmd=cmds.get(action)
    if cmd:
        return subprocess.run(cmd,shell=True,timeout=45).returncode==0

    ip=m["ip"]
    # Generic HTTP endpoints can be overridden in miners.json.
    url=m.get(f"{action}_url")
    if url:
        try:
            req=urllib.request.Request(url,method="POST")
            with urllib.request.urlopen(req,timeout=10) as r:
                return 200 <= r.status < 300
        except Exception: return False

    # Last resort: system reboot endpoint is intentionally NOT guessed.
    return False

def cooling_phase(m, seconds):
    name=m.get("name",m["ip"])
    # "stop_miner" should stop hashing while preserving controller/fans when firmware supports it.
    stopped=run_action(m,"stop_miner")
    if stopped: log("mineração parada; iniciando resfriamento",name)
    else: log("resfriamento iniciado; comando stop_miner indisponível/falhou",name)

    fan=run_action(m,"fans_100")
    if fan: log("ventoinhas solicitadas em 100% durante resfriamento",name)

    for left in range(seconds,0,-1):
        if left==seconds or left<=10 or left%30==0:
            log(f"RESFRIANDO: {left}s restantes",name)
        time.sleep(1)

def recover(m, st):
    name=m.get("name",m["ip"])
    st["state"]="cooling"; save_state(STATE_OBJ)
    cooling_phase(m,COOLDOWN)

    log("fim do resfriamento; executando recuperação",name)
    ok=run_action(m,"restart_miner")
    if not ok:
        ok=run_action(m,"reboot")
    if not ok:
        log("nenhum comando de restart/reboot respondeu",name)
        return False

    st["state"]="stabilizing"; save_state(STATE_OBJ)
    for left in range(STABILIZE,0,-1):
        if left==STABILIZE or left<=10 or left%60==0:
            log(f"ESTABILIZANDO: {left}s restantes",name)
        time.sleep(1)

    return tcp(m["ip"],int(m.get("port",80)),3)

def unhealthy(m):
    if not tcp(m["ip"],int(m.get("port",80)),2):
        return True,"offline"
    hr=detect_hashrate(m)
    expected=float(m.get("expected_ths",0) or 0)
    if hr is not None and expected>0 and hr < expected*MIN_RATIO:
        return True,f"hashrate baixo {hr:.2f} < {expected*MIN_RATIO:.2f}"
    return False,"ok"

STATE_OBJ=load_json(STATE,{})
log("ASIC watchdog iniciado")

while True:
    cfg=load_json(CFG,{"miners":[]})
    for m in cfg.get("miners",[]):
        if not m.get("enabled",True): continue
        name=m.get("name",m.get("ip","unknown"))
        key=m.get("id") or m.get("ip")
        if not key or not m.get("ip"): continue
        st=STATE_OBJ.setdefault(key,{"fails":0,"retries":0,"state":"ok","next_retry":0})
        bad,reason=unhealthy(m)
        now=time.time()
        if not bad:
            if st.get("state")!="ok" or st.get("fails",0):
                log("máquina saudável novamente",name)
            st.update({"fails":0,"retries":0,"state":"ok","next_retry":0})
            save_state(STATE_OBJ)
            continue

        st["fails"]=st.get("fails",0)+1
        log(f"falha detectada ({st['fails']}/{FAIL_CONFIRM}): {reason}",name)
        save_state(STATE_OBJ)
        if st["fails"] < FAIL_CONFIRM: continue
        if now < st.get("next_retry",0): continue
        if st.get("retries",0) >= MAX_RETRIES:
            st["state"]="locked"
            log("limite de tentativas atingido; reinício automático bloqueado até máquina voltar saudável",name)
            save_state(STATE_OBJ)
            continue

        st["retries"]=st.get("retries",0)+1
        log(f"tentativa automática {st['retries']}/{MAX_RETRIES}",name)
        ok=recover(m,st)
        if ok:
            log("controladora respondeu após recuperação; aguardando telemetria",name)
            st["fails"]=0
        else:
            log("recuperação falhou",name)
            st["next_retry"]=time.time()+BACKOFF
        save_state(STATE_OBJ)
    time.sleep(POLL)
PY
chmod +x "$ROOT/usr/local/lib/nexhash/asic_watchdog.py"

cat > "$ROOT/etc/nexhash/miners.json" <<'EOF'
{
  "miners": [
    {
      "id": "miner-1",
      "name": "ASIC 1",
      "ip": "192.168.1.100",
      "enabled": false,
      "port": 80,
      "expected_ths": 120,
      "commands": {
        "stop_miner": "",
        "fans_100": "",
        "restart_miner": "",
        "reboot": ""
      }
    }
  ]
}
EOF

cat > "$ROOT/etc/systemd/system/nexhash-asic-watchdog.service" <<'EOF'
[Unit]
Description=NexHash ASIC Auto-Recovery Watchdog
After=network-online.target nexhash.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/nexhash/device.env
ExecStart=/usr/bin/python3 /usr/local/lib/nexhash/asic_watchdog.py
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/var/lib/nexhash /var/log/nexhash /etc/nexhash

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOT/usr/local/bin/nexhash-open" <<'EOF'
#!/usr/bin/env bash
set -u
URL="http://127.0.0.1:${NEXHASH_PORT:-8787}"
for i in $(seq 1 90); do
  if curl -fsS --max-time 2 "$URL" >/dev/null 2>&1; then
    exec opera --start-maximized "$URL"
  fi
  sleep 2
done
exec opera --start-maximized "$URL"
EOF
chmod +x "$ROOT/usr/local/bin/nexhash-open"

cat > "$ROOT/usr/local/bin/nexhashctl" <<'EOF'
#!/usr/bin/env bash
set -e
case "${1:-status}" in
  status) systemctl --no-pager --full status nexhash.service nexhash-asic-watchdog.service tailscaled.service ;;
  restart) sudo -n systemctl restart nexhash.service ;;
  logs) journalctl -u nexhash.service -u nexhash-asic-watchdog.service -n 200 --no-pager ;;
  watchdog-log) tail -n 200 /var/log/nexhash/asic-watchdog.log ;;
  tailscale-status) tailscale status ;;
  tailscale-login) sudo -n tailscale up ;;
  health) curl -fsS "http://127.0.0.1:${NEXHASH_PORT:-8787}" >/dev/null && echo "NexHash OK :8787" || { echo "NexHash OFFLINE"; exit 1; } ;;
  *) echo "uso: nexhashctl {status|restart|logs|watchdog-log|tailscale-status|tailscale-login|health}"; exit 2 ;;
esac
EOF
chmod +x "$ROOT/usr/local/bin/nexhashctl"

# Auto-open Opera on graphical login
install -d "$ROOT/etc/skel/.config/autostart"
cat > "$ROOT/etc/skel/.config/autostart/nexhash-open.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=NexHash
Exec=/usr/local/bin/nexhash-open
X-KDE-autostart-after=panel
Terminal=false
NoDisplay=true
EOF

# Enable units in an offline rootfs without invoking systemd.
install -d "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf ../nexhash.service "$ROOT/etc/systemd/system/multi-user.target.wants/nexhash.service"
ln -sf ../nexhash-asic-watchdog.service "$ROOT/etc/systemd/system/multi-user.target.wants/nexhash-asic-watchdog.service"

echo "NexHash appliance layer installed into $ROOT"
