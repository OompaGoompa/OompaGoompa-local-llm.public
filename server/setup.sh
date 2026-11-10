#!/usr/bin/env bash
# One-step setup of a private model server for the Local LLM iPhone app.
# Run on the server (Ubuntu or Oracle Linux, Arm or x86):
#   curl -fsSL https://raw.githubusercontent.com/OompaGoompa/OompaGoompa-local-llm.public/app/server/setup.sh | bash
# Optional: choose the model yourself, e.g.  ... | bash -s -- llama3.2:3b
set -euo pipefail

MODEL="${1:-auto}"
NAME="llm-server"
PORT=11434

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "1/4 Installing Ollama (runs the models)"
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:%s"\nEnvironment="OLLAMA_KEEP_ALIVE=30m"\n' "$PORT" |
  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable ollama >/dev/null 2>&1 || true
sudo systemctl restart ollama

say "2/4 Installing Tailscale (private link between this server and your phone)"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! sudo tailscale status >/dev/null 2>&1; then
  echo "Open the link below on your phone and sign in. Setup continues by itself afterwards."
fi
sudo tailscale up --hostname="$NAME"

say "3/4 Allowing the app in through the private link only"
# The model port is opened on the Tailscale interface, never on the public internet side.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null 2>&1 || true
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  if ! sudo iptables -C INPUT -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 -i tailscale0 -p tcp --dport "$PORT" -j ACCEPT
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null 2>&1 || true
  fi
fi

say "4/4 Downloading a model"
if [ "$MODEL" = "auto" ]; then
  GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if   [ "$GB" -lt 7 ];  then MODEL="llama3.2:3b"
  elif [ "$GB" -lt 15 ]; then MODEL="qwen2.5:7b"
  else                        MODEL="qwen2.5:14b"
  fi
  echo "This server has about ${GB} GB of memory, so the model will be $MODEL."
fi
for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1 && break
  sleep 1
done
if ! ollama pull "$MODEL"; then
  echo "The model could not be downloaded. The server still works; add one later with:  ollama pull <name>"
fi

IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
say "Done"
cat <<MSG
In the Local LLM app: Settings > Remote server
  Address:  http://$NAME:$PORT
  (if that does not connect, use  http://${IP:-<this server's Tailscale IP>}:$PORT)
Then tap "Connect and list models", choose $MODEL, and turn on "Run on another computer".
Keep the Tailscale app switched on on your phone whenever you use the server.

More models later:  ollama pull <name>     List them:  ollama list
MSG
