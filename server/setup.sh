#!/usr/bin/env bash
# One-step setup of a private model server for the Local LLM iPhone app.
# Run on the server (Ubuntu or Oracle Linux, Arm or x86):
#   curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/setup.sh | bash
# Optional: choose the model yourself, e.g.  ... | bash -s -- llama3.2:3b
#
# With no login at all (new VM): paste the startup script from the app into the cloud's "Initialization script"
# box. It runs this file with TS_AUTHKEY set, so Tailscale signs in by itself. Progress: /var/log/llm-setup.log
#
# Order matters: the private link (Tailscale) comes first, so the server shows up on the phone within a few
# minutes even while the rest is still installing. Each step retries, because a freshly booted machine is often
# still busy updating itself.
set -uo pipefail

export HOME="${HOME:-/root}"
MODEL="${1:-auto}"
NAME="llm-server"
PORT=11434

say() { printf '\n== %s\n' "$*"; }

# On a first-boot run, also show progress on the machine's console (visible in the cloud console's boot log).
if [ -n "${TS_AUTHKEY:-}" ] && [ -w /dev/console ]; then
  exec > >(tee /dev/console) 2>&1
fi

# retry <attempts> <seconds between> <command...>
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

install_tailscale() { command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sh; }; }
install_ollama()    { command -v ollama    >/dev/null 2>&1 || { curl -fsSL https://ollama.com/install.sh    | sh; }; }
online()            { curl -fsS -o /dev/null --max-time 10 https://pkgs.tailscale.com/; }
ollama_up()         { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/api/version"; }

say "Waiting for the internet connection"
retry 30 10 online || echo "   still no internet; carrying on anyway"

say "1/4 Tailscale (private link between this server and your phone)"
if ! retry 10 30 install_tailscale; then
  echo "FAILED: Tailscale could not be installed."
  exit 1
fi
sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true
sleep 2
if [ -n "${TS_AUTHKEY:-}" ]; then
  if ! retry 5 15 sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$NAME"; then
    echo "FAILED: Tailscale did not accept the key. Make a new auth key and try again."
    exit 1
  fi
else
  if ! sudo tailscale status >/dev/null 2>&1; then
    echo "Open the link below on your phone and sign in. Setup continues by itself afterwards."
  fi
  sudo tailscale up --hostname="$NAME" || { echo "FAILED: Tailscale sign-in did not finish."; exit 1; }
fi
echo "   joined as $NAME ($(tailscale ip -4 2>/dev/null | head -n1))"

say "2/4 Letting the app in through the private link only"
# The model port is opened on the Tailscale interface, never on the public internet side.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null 2>&1 || true
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  if ! sudo iptables -C INPUT -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT || true
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null 2>&1 || true
  fi
fi

say "3/4 Ollama (runs the models)"
# Ollama's installer unpacks with zstd, which a fresh Oracle Linux or Ubuntu image may not have.
install_zstd() {
  command -v zstd >/dev/null 2>&1 && return 0
  if   command -v dnf     >/dev/null 2>&1; then sudo dnf install -y zstd
  elif command -v yum     >/dev/null 2>&1; then sudo yum install -y zstd
  elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y zstd
  fi
  command -v zstd >/dev/null 2>&1
}
retry 10 30 install_zstd || echo "   zstd could not be installed; trying Ollama anyway"
if ! retry 5 30 install_ollama; then
  echo "FAILED: Ollama could not be installed."
  exit 1
fi
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:%s"\nEnvironment="OLLAMA_KEEP_ALIVE=30m"\n' "$PORT" |
  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable ollama >/dev/null 2>&1 || true
sudo systemctl restart ollama || true
retry 30 2 ollama_up >/dev/null || echo "   Ollama is slow to start; carrying on"

say "4/4 Downloading a model"
if [ "$MODEL" = "auto" ]; then
  GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if   [ "$GB" -lt 7 ];  then MODEL="llama3.2:3b"
  elif [ "$GB" -lt 15 ]; then MODEL="qwen2.5:7b"
  else                        MODEL="qwen2.5:14b"
  fi
  echo "This server has about ${GB} GB of memory, so the model will be $MODEL."
fi
if ! retry 3 20 ollama pull "$MODEL"; then
  echo "The model could not be downloaded. The server still works; add one from the app (Server models)."
fi

IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
[ -n "$IP" ] || IP="the 100.x.y.z address shown in the Tailscale app"
say "Done"
cat <<MSG
In the Local LLM app: Settings > Remote server
  Address:  http://$NAME:$PORT
  (if that does not connect, use  http://$IP:$PORT)
Then tap "Connect and list models", choose $MODEL, and turn on "Run on another computer".
Keep the Tailscale app switched on on your phone whenever you use the server.

More models: in the app under Server models, or here with  ollama pull <name>
MSG
