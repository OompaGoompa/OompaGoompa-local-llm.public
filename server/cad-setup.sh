#!/usr/bin/env bash
# Adds the 3D builder to a Local LLM server: OpenSCAD plus a small service that turns OpenSCAD code into a
# printable shape. Run on the server after setup.sh:
#   curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/cad-setup.sh | bash
# The service listens on port 11435 and is reachable only through Tailscale, like the model server.
set -uo pipefail

PORT=11435
DIR=/opt/llm-cad

say() { printf '\n== %s\n' "$*"; }
retry() {
  local n="$1" wait="$2" i
  shift 2
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    echo "   attempt $i of $n failed; trying again in ${wait}s"
    sleep "$wait"
  done
  return 1
}

install_openscad() {
  command -v openscad >/dev/null 2>&1 && return 0
  if command -v dnf >/dev/null 2>&1; then
    # Oracle Linux keeps OpenSCAD in its EPEL mirror (ol9_developer_EPEL), which is installed but switched off
    # by default, and needs the CodeReady Builder repository alongside.
    sudo dnf install -y oracle-epel-release-el9 >/dev/null 2>&1 || sudo dnf install -y epel-release >/dev/null 2>&1 || true
    sudo dnf config-manager --set-enabled ol9_developer_EPEL >/dev/null 2>&1 || true
    sudo dnf config-manager --set-enabled ol9_codeready_builder >/dev/null 2>&1 || sudo dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
    sudo dnf install -y --enablerepo=ol9_developer_EPEL --enablerepo=ol9_codeready_builder openscad \
      || sudo dnf install -y openscad \
      || { sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && sudo dnf install -y openscad; }
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openscad
  fi
  command -v openscad >/dev/null 2>&1
}

say "1/3 Installing OpenSCAD (turns code into 3D shapes)"
if ! retry 3 20 install_openscad; then
  echo "FAILED: OpenSCAD could not be installed."
  exit 1
fi
command -v python3 >/dev/null 2>&1 || sudo dnf install -y python3 || sudo apt-get install -y python3
echo "   $(openscad --version 2>&1 | head -n1)"

say "2/3 Installing the 3D builder service"
sudo mkdir -p "$DIR"
sudo tee "$DIR/cad_server.py" >/dev/null <<'PY'
#!/usr/bin/env python3
"""Turns OpenSCAD code into an ASCII STL. POST the code to /render; GET /health to check it is alive."""
import http.server
import os
import shutil
import struct
import subprocess
import tempfile
import threading

PORT = int(os.environ.get("LLM_CAD_PORT", "11435"))
MAX_SOURCE = 300_000
TIMEOUT = 180
OPENSCAD = shutil.which("openscad") or "/usr/bin/openscad"
LOCK = threading.Lock()


def to_ascii(data):
    """Returns ASCII STL text whether OpenSCAD wrote the text or the binary kind."""
    head = data[:512].lstrip()
    if head.startswith(b"solid") and b"facet" in data[:4096]:
        return data.decode("utf-8", "replace")
    if len(data) < 84:
        return ""
    count = struct.unpack_from("<I", data, 80)[0]
    lines = ["solid model"]
    offset = 84
    for _ in range(count):
        if offset + 50 > len(data):
            break
        v = struct.unpack_from("<12f", data, offset)
        offset += 50
        lines.append("facet normal %g %g %g" % v[0:3])
        lines.append(" outer loop")
        for k in (3, 6, 9):
            lines.append("  vertex %g %g %g" % v[k:k + 3])
        lines.append(" endloop")
        lines.append("endfacet")
    lines.append("endsolid model")
    return "\n".join(lines) + "\n"


def version():
    try:
        r = subprocess.run([OPENSCAD, "--version"], capture_output=True, timeout=20)
        return (r.stdout + r.stderr).decode("utf-8", "replace").strip().splitlines()[0]
    except Exception as e:  # noqa: BLE001
        return "openscad not working: %s" % e


def render(source):
    """Returns (ok, text): the STL on success, OpenSCAD's own messages on failure."""
    work = tempfile.mkdtemp(prefix="llmcad-")
    try:
        src = os.path.join(work, "model.scad")
        out = os.path.join(work, "model.stl")
        with open(src, "wb") as f:
            f.write(source)
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", HOME=work, XDG_CACHE_HOME=work, XDG_CONFIG_HOME=work)
        log = b""
        for extra in (["--export-format", "asciistl"], []):
            try:
                r = subprocess.run([OPENSCAD, "-o", out] + extra + [src], capture_output=True, timeout=TIMEOUT, cwd=work, env=env)
            except subprocess.TimeoutExpired:
                return False, "The shape took longer than %d seconds to build. Make it simpler or lower $fn." % TIMEOUT
            log = r.stdout + r.stderr
            if os.path.exists(out) and os.path.getsize(out) > 0:
                with open(out, "rb") as f:
                    text = to_ascii(f.read())
                if "vertex" in text:
                    return True, text
            if b"export-format" not in log:
                break
        message = log.decode("utf-8", "replace").replace(work + "/", "").strip()
        return False, (message[-3000:] or "OpenSCAD produced no shape.")
    finally:
        shutil.rmtree(work, ignore_errors=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self.reply(200, "ok\n" + version() + "\n")
        else:
            self.reply(404, "not found\n")

    def do_POST(self):
        if not self.path.startswith("/render"):
            self.reply(404, "not found\n")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_SOURCE:
            self.reply(413, "The code is empty or too long.\n")
            return
        source = self.rfile.read(length)
        with LOCK:
            ok, text = render(source)
        self.reply(200 if ok else 422, text)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY
sudo chmod 755 "$DIR/cad_server.py"
id llmcad >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /sbin/nologin llmcad

sudo tee /etc/systemd/system/llm-cad.service >/dev/null <<UNIT
[Unit]
Description=Local LLM 3D builder (OpenSCAD to STL)
After=network-online.target
Wants=network-online.target

[Service]
User=llmcad
Environment=LLM_CAD_PORT=$PORT
ExecStart=/usr/bin/env python3 $DIR/cad_server.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable llm-cad >/dev/null 2>&1 || true
sudo systemctl restart llm-cad

# Reachable through Tailscale only, never from the public internet side.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null 2>&1 || true
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  if ! sudo iptables -C INPUT -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT || true
  fi
  command -v netfilter-persistent >/dev/null 2>&1 && sudo netfilter-persistent save >/dev/null 2>&1 || true
fi

say "3/3 Testing with a 10 mm cube"
alive() { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/health"; }
retry 15 2 alive >/dev/null || true
RESULT=$(curl -sS --max-time 120 -X POST --data-binary 'cube(10);' "http://127.0.0.1:$PORT/render" 2>&1 || true)
FACETS=$(printf '%s\n' "$RESULT" | grep -c "facet normal" || true)
if [ "${FACETS:-0}" -ge 12 ]; then
  say "Done"
  echo "The 3D builder works (test cube: $FACETS triangles)."
  echo "In the Local LLM app: Settings > Remote server > 3D builder > Check, then ask the AI for OpenSCAD code."
else
  say "The test did not pass"
  echo "The service answered:"
  printf '%s\n' "$RESULT" | head -n 20
  echo "--- service log ---"
  sudo journalctl -u llm-cad -n 15 --no-pager 2>/dev/null || true
  exit 1
fi
