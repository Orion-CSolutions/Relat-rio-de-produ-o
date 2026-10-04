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
BRAIINS_PAUSED_FAN_PWM=100
BRAIINS_PAUSE_FAN_RUNTIME=indefinitely
EOF

cat > "$ROOT/usr/local/bin/nexhash-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/nexhash/current
export PORT="${NEXHASH_PORT:-8787}"
export HOST="${NEXHASH_BIND:-0.0.0.0}"

# EdgeOS is the LOCAL bridge/appliance. Production Cloud Docker Compose stays
# available under ./deploy but is not auto-started because it expects public
# DNS domains and Caddy TLS.
if [ ! -f .env ] && [ -f .env.example ]; then
  cp .env.example .env
fi

# V1.5 frontend defaults to this local token. Keep first boot aligned so the
# dashboard works immediately. Tailscale provides the private network boundary.
if [ -f .env ]; then
  if grep -Eq '^BRIDGE_TOKEN=(troque-|$)' .env 2>/dev/null; then
    sed -i 's#^BRIDGE_TOKEN=.*#BRIDGE_TOKEN=miner-control-local#' .env
  fi
fi

if [ -x ./run.sh ]; then exec ./run.sh; fi

# NexHash V5.2.2 local server is the preferred appliance runtime.
if [ -f package.json ]; then
  if [ ! -d node_modules ]; then
    npm install --omit=dev
  fi
  if node -e 'let p=require("./package.json");process.exit(p.scripts&&p.scripts.start?0:1)'; then
    exec npm start
  fi
fi

if [ -f requirements.txt ]; then pip3 install --break-system-packages -r requirements.txt; fi
if [ -f app.py ]; then exec python3 app.py; fi
if [ -f server.py ]; then exec python3 server.py; fi
if [ -f main.py ]; then exec python3 main.py; fi

echo "NexHash application package not found; starting appliance bootstrap on :${PORT}" >&2
exec python3 /usr/local/lib/nexhash/bootstrap_server.py
EOF
chmod +x "$ROOT/usr/local/bin/nexhash-run"

cat > "$ROOT/usr/local/lib/nexhash/bootstrap_server.py" <<'PY_BOOT'
#!/usr/bin/env python3
import json, os, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT=int(os.environ.get("PORT","8787"))
HOST=os.environ.get("HOST","0.0.0.0")

HTML="""<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>NexHash EdgeOS</title><style>
body{margin:0;background:#07111f;color:#eef5ff;font-family:system-ui,-apple-system,Segoe UI,sans-serif;display:grid;place-items:center;min-height:100vh}
.card{width:min(760px,90vw);background:#0d1a2b;border:1px solid #1c3557;border-radius:22px;padding:36px;box-shadow:0 24px 70px #0007}
h1{margin:0 0 10px;font-size:38px}.blue{color:#278cff}p{color:#aabbd0;line-height:1.55}
.badge{display:inline-block;padding:8px 12px;border-radius:999px;background:#13243a;border:1px solid #28517d;margin-top:10px}
small{color:#7f93aa}
</style></head><body><div class='card'>
<h1>Nex<span class='blue'>Hash</span> EdgeOS</h1>
<p>Appliance online. O serviço principal está ativo e aguardando o pacote NexHash de produção em <b>/opt/nexhash/current</b>.</p>
<div class='badge'>Servidor :8787 operacional</div>
<p><small>Rede, Tailscale, watchdog de ASIC e diagnóstico continuam ativos independentemente do navegador.</small></p>
</div></body></html>"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health","/api/health"):
            b=json.dumps({"ok":True,"service":"nexhash-bootstrap","host":socket.gethostname(),"port":PORT}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        b=HTML.encode()
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass

ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY_BOOT
chmod +x "$ROOT/usr/local/lib/nexhash/bootstrap_server.py"

install -d "$ROOT/etc/skel/.config/autostart"

cat > "$ROOT/usr/local/bin/nexhash-tailscale-autoconnect" <<'EOF'
#!/usr/bin/env bash
set -u
systemctl start tailscaled >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  tailscale status >/dev/null 2>&1 && exit 0
  sleep 2
done

# Optional secure provisioning path. The key is never committed to the ISO.
if [ -s /etc/nexhash/tailscale-authkey ]; then
  KEY="$(cat /etc/nexhash/tailscale-authkey)"
  tailscale up --auth-key="$KEY" --hostname=nexhash-edge --accept-dns=true
  shred -u /etc/nexhash/tailscale-authkey 2>/dev/null || rm -f /etc/nexhash/tailscale-authkey
  exit $?
fi

# If the machine was authenticated before, tailscaled's persistent state reconnects automatically.
# Otherwise start login non-interactively and expose only the short-lived approval URL locally.
OUT="$(timeout 18s tailscale up --hostname=nexhash-edge --accept-dns=true 2>&1 || true)"
URL="$(printf '%s\n' "$OUT" | grep -Eo 'https://login\.tailscale\.com/[^ ]+' | head -n1 || true)"
if [ -n "$URL" ]; then
  install -d -m 0755 /run/nexhash
  printf '%s\n' "$URL" > /run/nexhash/tailscale-login-url
  chmod 0644 /run/nexhash/tailscale-login-url
fi
exit 0
EOF
chmod +x "$ROOT/usr/local/bin/nexhash-tailscale-autoconnect"

cat > "$ROOT/usr/local/bin/nexhash-tailscale-onboarding" <<'EOF'
#!/usr/bin/env bash
set -u
for i in $(seq 1 90); do
  if tailscale status >/dev/null 2>&1; then
    exit 0
  fi
  if [ -s /run/nexhash/tailscale-login-url ]; then
    URL="$(head -n1 /run/nexhash/tailscale-login-url)"
    exec opera --new-window "$URL"
  fi
  sleep 2
done
exit 0
EOF
chmod +x "$ROOT/usr/local/bin/nexhash-tailscale-onboarding"

cat > "$ROOT/etc/skel/.config/autostart/nexhash-tailscale-onboarding.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=NexHash Tailscale Setup
Exec=/usr/local/bin/nexhash-tailscale-onboarding
X-KDE-autostart-after=panel
Terminal=false
NoDisplay=true
EOF

cat > "$ROOT/etc/systemd/system/nexhash-tailscale-autoconnect.service" <<'EOF'
[Unit]
Description=NexHash Tailscale Auto-Reconnect
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nexhash-tailscale-autoconnect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOT/usr/local/lib/nexhash/health_server.py" <<'PY_HEALTH'
#!/usr/bin/env python3
import json, os, shutil, socket, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def sh(cmd):
    try: return subprocess.check_output(cmd,shell=True,text=True,stderr=subprocess.DEVNULL,timeout=3).strip()
    except Exception: return ""

def payload():
    total,used,free=sh("free -m | awk '/Mem:/{print $2,$3,$4}'").split() if sh("free -m | awk '/Mem:/{print $2,$3,$4}'") else ("0","0","0")
    du=sh("df -P / | awk 'NR==2{print $2,$3,$4,$5}'").split()
    return {
      "ok":True,"host":socket.gethostname(),"uptime":sh("uptime -p"),
      "ip":sh("hostname -I"),"tailscale_ip":sh("tailscale ip -4 | head -n1"),
      "nexhash":sh("systemctl is-active nexhash.service"),
      "asic_watchdog":sh("systemctl is-active nexhash-asic-watchdog.service"),
      "tailscale":sh("systemctl is-active tailscaled.service"),
      "memory_mb":{"total":total,"used":used,"free":free},
      "disk":du
    }

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b=json.dumps(payload(),ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass

ThreadingHTTPServer(("0.0.0.0",8790),H).serve_forever()
PY_HEALTH
chmod +x "$ROOT/usr/local/lib/nexhash/health_server.py"

cat > "$ROOT/etc/systemd/system/nexhash-health.service" <<'EOF'
[Unit]
Description=NexHash EdgeOS Health API
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/nexhash/health_server.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

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
import json, os, socket, subprocess, time, urllib.request, urllib.error, urllib.parse
from pathlib import Path
from datetime import datetime, timezone

STATE=Path("/var/lib/nexhash/asic-watchdog.json")
LOG=Path("/var/log/nexhash/asic-watchdog.log")
CFG=Path("/etc/nexhash/miners.json")
FLEET=Path("/opt/nexhash/current/data/fleet.json")
APP_ENV=Path("/opt/nexhash/current/.env")
APP_ENV_EXAMPLE=Path("/opt/nexhash/current/.env.example")

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

def http_json(url,timeout=3,headers=None):
    try:
        req=urllib.request.Request(url,headers=headers or {})
        with urllib.request.urlopen(req,timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8","ignore"))
    except Exception: return None

def read_env(path):
    out={}
    try:
        for raw in Path(path).read_text(encoding="utf-8").splitlines():
            line=raw.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k,v=line.split("=",1)
            out[k.strip()]=v.strip().strip('"').strip("'")
    except Exception: pass
    return out

def nexhash_token():
    return read_env(APP_ENV).get("BRIDGE_TOKEN") or read_env(APP_ENV_EXAMPLE).get("BRIDGE_TOKEN") or ""

def nexhash_headers():
    t=nexhash_token()
    return {"Authorization":f"Bearer {t}"} if t else {}

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

def nexhash_api_action(m, action):
    mid=str(m.get("id") or "")
    if not mid: return False
    amap={"stop_miner":"pause","restart_miner":"restart","resume":"resume","reboot":"reboot"}
    act=amap.get(action)
    if not act: return False
    token=nexhash_token()
    if not token: return False
    try:
        body=json.dumps({"action":act}).encode()
        req=urllib.request.Request(
            f"http://127.0.0.1:8787/api/internal/watchdog/miners/{urllib.parse.quote(mid,safe='')}/action",
            data=body,method="POST",
            headers={"Authorization":f"Bearer {token}","Content-Type":"application/json"}
        )
        with urllib.request.urlopen(req,timeout=20) as r:
            ok=200 <= r.status < 300
            reply=r.read().decode("utf-8","ignore")[-800:]
        log(f"NexHash action {act}: HTTP {r.status} {reply}",m.get("name",m.get("ip")))
        return ok
    except Exception as e:
        log(f"NexHash action {act} falhou: {e}",m.get("name",m.get("ip")))
        return False

def nexhash_snapshot(m):
    data=http_json("http://127.0.0.1:8787/api/internal/watchdog/miners",2,nexhash_headers())
    if not isinstance(data,list): return None
    mid=str(m.get("id") or "")
    ip=str(m.get("ip") or "")
    for row in data:
        if not isinstance(row,dict): continue
        if (mid and str(row.get("id") or "")==mid) or str(row.get("host") or row.get("ip") or "")==ip:
            return row
    return None

def miner_password(m):
    # Prefer root-only password files. Inline password remains supported for migration only.
    p=m.get("password_file")
    if p:
        try: return Path(p).read_text(encoding="utf-8").strip()
        except Exception: return ""
    return str(m.get("password","") or "")

def toolbox(m, args, timeout=45):
    ip=m["ip"]
    pw=miner_password(m)
    cmd=["/usr/local/bin/braiins-toolbox"]
    if pw:
        cmd += ["-p", pw]
    cmd += args + [ip]
    try:
        r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
        log("Braiins Toolbox: " + (r.stdout.strip()[-800:] or f"exit={r.returncode}"),m.get("name",ip))
        return r.returncode==0
    except Exception as e:
        log(f"Braiins Toolbox exception: {e}",m.get("name",ip))
        return False

def bosminer_api(ip, command, timeout=4):
    # Legacy cgminer-style BOSminer API fallback.
    try:
        payload=json.dumps({"command":command}).encode()
        with socket.create_connection((ip,4028),timeout=timeout) as s:
            s.sendall(payload)
            s.settimeout(timeout)
            data=s.recv(8192)
        txt=data.decode("utf-8","ignore")
        return bool(txt) and ("STATUS" in txt or "STATUS=" in txt or "Description" in txt)
    except Exception:
        return False

def braiins_action(m, action):
    fw=str(m.get("firmware","")).lower()
    if fw not in ("braiins","braiinsos","braiins os","bos","bos+"):
        return False

    if action=="stop_miner":
        # Pause is deliberately used instead of a full device power-off:
        # hashing stops while the controller remains online for cooling/recovery.
        if toolbox(m,["miner","pause"]): return True
        return bosminer_api(m["ip"],"pause")

    if action=="fans_100":
        pwm=str(int(m.get("cooldown_fan_pwm",int(os.getenv("BRAIINS_PAUSED_FAN_PWM","100")))))
        # Supported BOS versions keep fans active while paused.
        args=["cooling","set","--fan-paused-mode","manual","--fan-paused-pwm",pwm]
        runtime=os.getenv("BRAIINS_PAUSE_FAN_RUNTIME","indefinitely")
        if runtime:
            with_runtime=args+["--fan-pause-runtime",runtime]
            if toolbox(m,with_runtime): return True
        # Older BOS versions may support paused fan PWM but not runtime.
        return toolbox(m,args)

    if action=="restart_miner":
        # Restart BOSminer/mining process, NOT the whole controller.
        return toolbox(m,["miner","restart"])

    if action=="reboot":
        return toolbox(m,["system","reboot"])

    if action=="resume":
        if toolbox(m,["miner","resume"]): return True
        return bosminer_api(m["ip"],"resume")
    return False

def run_action(m, action):
    cmds=m.get("commands",{})
    cmd=cmds.get(action)
    if cmd:
        return subprocess.run(cmd,shell=True,timeout=45).returncode==0

    if action in ("stop_miner","restart_miner","resume","reboot") and nexhash_api_action(m,action):
        return True

    if braiins_action(m,action):
        return True

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
        # If a firmware only supports pause/resume, resume is safer than rebooting hardware.
        ok=run_action(m,"resume")
    if not ok:
        ok=run_action(m,"reboot")
    if not ok:
        log("nenhum comando de restart/resume/reboot respondeu",name)
        return False

    st["state"]="stabilizing"; save_state(STATE_OBJ)
    for left in range(STABILIZE,0,-1):
        if left==STABILIZE or left<=10 or left%60==0:
            log(f"ESTABILIZANDO: {left}s restantes",name)
        time.sleep(1)

    return tcp(m["ip"],int(m.get("port",80)),3)

def unhealthy(m):
    ip=m["ip"]
    snap=nexhash_snapshot(m)

    # NexHash knows whether telemetry is fresh. If it explicitly reports offline,
    # treat it as a failure; an intentional paused/running=false miner is not
    # automatically restarted unless the control process/API itself disappears.
    if isinstance(snap,dict):
        if snap.get("online") is False:
            return True,"NexHash reportou ASIC offline"
        hr=snap.get("hashrate5s",snap.get("hashrate"))
        try: hr=float(hr) if hr is not None else None
        except Exception: hr=None
        expected=float(m.get("expected_ths",0) or 0)
        if hr is not None and expected>0 and hr < expected*MIN_RATIO and snap.get("running") is not False:
            return True,f"hashrate baixo {hr:.2f} < {expected*MIN_RATIO:.2f}"

    web_ok=tcp(ip,int(m.get("port",80)),2)
    miner_api_ok=tcp(ip,4028,2)
    if not web_ok and not miner_api_ok:
        return True,"ASIC/controladora offline"
    if web_ok and not miner_api_ok and str(m.get("firmware","")).lower() in ("braiins","braiinsos","braiins os","bos","bos+"):
        return True,"BOSminer API 4028 indisponível"

    hr=detect_hashrate(m)
    expected=float(m.get("expected_ths",0) or 0)
    if hr is not None and expected>0 and hr < expected*MIN_RATIO:
        return True,f"hashrate baixo {hr:.2f} < {expected*MIN_RATIO:.2f}"
    return False,"ok"

def normalize_miners(obj):
    if isinstance(obj,list): items=obj
    elif isinstance(obj,dict):
        items=obj.get("miners") or obj.get("machines") or obj.get("devices") or obj.get("items") or []
    else: items=[]
    out=[]
    for x in items:
        if not isinstance(x,dict): continue
        ip=x.get("ip") or x.get("host") or x.get("address")
        if not ip: continue
        m=dict(x)
        m["ip"]=str(ip)
        m.setdefault("id",str(x.get("id") or x.get("uuid") or ip))
        m.setdefault("name",str(x.get("name") or x.get("alias") or x.get("model") or ip))
        fw=str(x.get("firmware") or x.get("firmware_name") or "").lower()
        if "braiins" in fw or fw in ("bos","bos+"):
            m["firmware"]="braiins"
        m.setdefault("enabled",True)
        out.append(m)
    return out

def get_registered_miners():
    # 1) NexHash persistent fleet — follows additions/removals made in the UI.
    persisted=normalize_miners(load_json(FLEET,{"miners":[]}))
    if persisted:
        return persisted

    # 2) Authenticated live API.
    data=http_json("http://127.0.0.1:8787/api/miners",2,nexhash_headers())
    live=normalize_miners(data)
    if live:
        return live

    # 3) Seed MINERS_JSON from the packaged local .env.
    for p in (APP_ENV,APP_ENV_EXAMPLE):
        raw=read_env(p).get("MINERS_JSON","")
        if raw:
            try:
                seeded=normalize_miners(json.loads(raw))
                if seeded: return seeded
            except Exception: pass

    # 4) Appliance fallback config.
    return normalize_miners(load_json(CFG,{"miners":[]}))

STATE_OBJ=load_json(STATE,{})
log("ASIC watchdog iniciado")

while True:
    miners=get_registered_miners()
    for m in miners:
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
      "firmware": "braiins",
      "password_file": "/etc/nexhash/miner-secrets/miner-1.password",
      "cooldown_fan_pwm": 100,
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
install -d -m 0700 "$ROOT/etc/nexhash/miner-secrets"
chmod 0600 "$ROOT/etc/nexhash/miners.json"

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
ln -sf ../nexhash-health.service "$ROOT/etc/systemd/system/multi-user.target.wants/nexhash-health.service"
ln -sf ../nexhash-tailscale-autoconnect.service "$ROOT/etc/systemd/system/multi-user.target.wants/nexhash-tailscale-autoconnect.service"

echo "NexHash appliance layer installed into $ROOT"
