#!/usr/bin/env bash
set -euo pipefail

AUTH_KEY="${1:-${TAILSCALE_AUTH_KEY:-}}"

run_as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "❌ Need root privileges (run as root or install sudo)."
    exit 1
  fi
}

echo "== Tailscale bootstrap =="
echo "Tailscale is private tailnet access, not public internet exposure."
echo "Use Tailscale IP/SSH for admin access; keep public firewall ports closed unless explicitly needed."

if ! command -v tailscale >/dev/null 2>&1; then
  echo "Installing Tailscale..."
  run_as_root bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
else
  echo "Tailscale already installed."
fi

if [ -n "$AUTH_KEY" ]; then
  echo "Running tailscale up with provided auth key..."
  run_as_root tailscale up --auth-key "$AUTH_KEY"
else
  echo "No auth key provided."
  echo "Authenticate later with:"
  echo "  sudo tailscale up"
fi

echo "Current Tailscale status:"
run_as_root tailscale status || true

echo "Private access reminder:"
echo "  tailscale ip"
echo "  ssh <user>@<tailscale-ip-or-hostname>"
echo "No public port publishing is required for Tailscale-only admin access."

echo "Done."
