#!/usr/bin/env bash
# OpenClaw VM Security Setup Script
# Run this script as root on a fresh Ubuntu VM.

set -euo pipefail
trap 'rm -f /root/after.rules.tmp.* /root/after6.rules.tmp.* 2>/dev/null || true' EXIT

# --- Configuration ---
OPENCLAW_USER="clawdbot"
ADMIN_USER="${1:?Usage: $0 <admin-username> <ssh-public-key> [tailscale-auth-key]}"
ADMIN_SSH_PUBKEY="${2:?Usage: $0 <admin-username> <ssh-public-key> [tailscale-auth-key]}"
TAILSCALE_AUTH_KEY="${3:-}"

if ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "❌ CRITICAL: Invalid admin username '$ADMIN_USER'."
  echo "   It must match: ^[a-z_][a-z0-9_-]{0,31}$"
    exit 1
fi

OPENCLAW_HOME="/home/$OPENCLAW_USER"
EXPECTED_ADMIN_HOME="/home/$ADMIN_USER"
ADMIN_HOME="$EXPECTED_ADMIN_HOME"
OC_STATE_DIR="$OPENCLAW_HOME/.openclaw"
GATEWAY_PORT=18789

# Script Locations based on the local directory this is run from
SCRIPT_DIR=$(dirname "$(realpath "$0")")
AUDIT_SCRIPT_SOURCE="$SCRIPT_DIR/nightly-security-audit.sh"

echo "🛡️ Starting OpenClaw VM Security Setup..."

# 0. Install Core Dependencies & Unattended Upgrades
echo "Installing prerequisites (including Docker, Fail2Ban, Unattended-Upgrades)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl git ufw fail2ban unattended-upgrades apt-listchanges jq openssl nodejs npm

echo "Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale already installed."
fi

if [ -z "$TAILSCALE_AUTH_KEY" ] && [ -t 0 ]; then
  read -r -p "Enter Tailscale auth key (leave blank to skip): " TAILSCALE_AUTH_KEY
fi

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  tailscale up --auth-key "$TAILSCALE_AUTH_KEY" || echo "⚠️ Tailscale auth failed. You can re-run: tailscale up --auth-key <key>"
else
  echo "⚠️ No Tailscale auth key provided. Skipping tailscale up."
fi

# Configure Unattended Upgrades for automatic security patching
echo "Configuring unattended-upgrades for security updates..."
cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Check if Docker is installed, if not, install it using the official APT repository
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing Docker Engine cleanly via apt..."
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "Docker is already installed."
fi

# Ensure docker service is enabled and running
systemctl enable docker
systemctl start docker

# 1. Create/Configure Admin User
if id "$ADMIN_USER" &>/dev/null; then
  echo "Admin user $ADMIN_USER already exists."
else
  echo "Creating admin user: $ADMIN_USER"
  useradd -m -d "$EXPECTED_ADMIN_HOME" -s /bin/bash "$ADMIN_USER"
fi

ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
if [ -z "$ADMIN_HOME" ]; then
  echo "❌ CRITICAL: Could not resolve home directory for $ADMIN_USER"
  exit 1
fi

if [ "$ADMIN_HOME" != "$EXPECTED_ADMIN_HOME" ]; then
  echo "Setting home directory for $ADMIN_USER to $EXPECTED_ADMIN_HOME"
  usermod -d "$EXPECTED_ADMIN_HOME" -m "$ADMIN_USER"
  ADMIN_HOME="$EXPECTED_ADMIN_HOME"
fi

install -d -m 755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME"

echo "Ensuring $ADMIN_USER is in sudo group..."
usermod -aG sudo "$ADMIN_USER"

echo "Installing SSH key for $ADMIN_USER..."
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
AUTH_KEYS_FILE="$ADMIN_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS_FILE"
chmod 600 "$AUTH_KEYS_FILE"
chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS_FILE"
if ! grep -Fxq "$ADMIN_SSH_PUBKEY" "$AUTH_KEYS_FILE"; then
  printf '%s\n' "$ADMIN_SSH_PUBKEY" >> "$AUTH_KEYS_FILE"
fi

echo "Installing OpenClaw CLI for $ADMIN_USER in $ADMIN_HOME/.npm-global..."
su - "$ADMIN_USER" -c 'mkdir -p "$HOME/.npm-global" && npm config set prefix "$HOME/.npm-global" && npm install -g openclaw@latest'
if [ ! -f "$ADMIN_HOME/.profile" ]; then
  touch "$ADMIN_HOME/.profile"
  chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.profile"
fi
if ! grep -Fq 'export PATH="$HOME/.npm-global/bin:$PATH"' "$ADMIN_HOME/.profile"; then
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$ADMIN_HOME/.profile"
  chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.profile"
fi

# 2. Create Subaccount
if id "$OPENCLAW_USER" &>/dev/null; then
    echo "User $OPENCLAW_USER already exists."
else
    echo "Creating minimal-permission subaccount: $OPENCLAW_USER"
    # Use nologin for defense-in-depth since this user only needs cron/su access
    useradd -m -s /usr/sbin/nologin "$OPENCLAW_USER"
    # Do NOT add to sudoers.
fi

# Add user to docker group
# WARNING: docker group = effective root. clawdbot can escalate via 'docker run -v /:/host'. 
# This is accepted for OpenClaw sandbox operations. 
# Mitigate by ensuring the sandbox itself restricts mounts, and clawdbot has no host creds.
echo "Adding $OPENCLAW_USER to the docker group for sandbox operations..."
usermod -aG docker "$OPENCLAW_USER"

# 2. Base Directories & File Permissions
echo "Setting up OpenClaw state directory and permissions..."
mkdir -p "$OC_STATE_DIR"
mkdir -p "$OC_STATE_DIR/devices"
mkdir -p "$OC_STATE_DIR/workspace/scripts"
mkdir -p "$OC_STATE_DIR/security-baselines"

# Create placeholder core configs if they don't exist
touch "$OC_STATE_DIR/openclaw.json"
touch "$OC_STATE_DIR/devices/paired.json"

# Strict permissions (Permission Narrowing)
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OC_STATE_DIR"
chmod 700 "$OC_STATE_DIR"
chmod 700 "$OC_STATE_DIR/workspace"
chmod 700 "$OC_STATE_DIR/workspace/scripts"
chmod 700 "$OC_STATE_DIR/devices"
chmod 700 "$OC_STATE_DIR/security-baselines"
chmod 600 "$OC_STATE_DIR/openclaw.json"
chmod 600 "$OC_STATE_DIR/devices/paired.json"

# 3. Secure Baseline Config Generation (Token + mDNS + IPv6 logic)
echo "Generating secure baseline config & Auth Token..."
# Generate a random 64-char hex token for Gateway Auth
NEW_GATEWAY_TOKEN=$(openssl rand -hex 32)
echo "--------------------------------------------------------"
echo "🔑 GATEWAY TOKEN GENERATED"
echo "(It has been securely written to $OC_STATE_DIR/openclaw.json)"
echo "--------------------------------------------------------"

# Write the secure baseline JSON via jq
jq -n \
  --arg token "$NEW_GATEWAY_TOKEN" \
  '{
    "gateway": {
      "mode": "local",
      "bind": "loopback",
      "port": 18789,
      "auth": { "mode": "token", "token": $token }
    },
    "session": { "dmScope": "per-channel-peer" },
    "tools": {
      "exec": { "security": "deny", "ask": "always" },
      "elevated": { "enabled": false },
      "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
      "fs": { "workspaceOnly": true }
    },
    "agents": {
      "defaults": {
        "sandbox": { "mode": "all", "scope": "agent", "workspaceAccess": "none" }
      }
    },
    "discovery": { "mdns": { "mode": "minimal" } },
    "logging": { "redactSensitive": "tools" }
  }' > "$OC_STATE_DIR/openclaw.json"

jq empty "$OC_STATE_DIR/openclaw.json" || { echo "❌ Config JSON invalid after write"; exit 1; }
unset NEW_GATEWAY_TOKEN

# 4. SSH Hardening & Fail2Ban
echo "Hardening SSH configuration..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

# Hardening settings
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"

# Advanced SSH lockdown (Add if they don't exist, or replace)
if ! grep -q "^LoginGraceTime" "$SSHD_CONFIG"; then echo "LoginGraceTime 20" >> "$SSHD_CONFIG"; else sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 20/' "$SSHD_CONFIG"; fi
if ! grep -q "^MaxAuthTries" "$SSHD_CONFIG"; then echo "MaxAuthTries 3" >> "$SSHD_CONFIG"; else sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"; fi

# Ensure only the admin user is explicitly allowed (WARN: This locks out clawdbot from SSH entirely)
if ! grep -q "^AllowUsers" "$SSHD_CONFIG"; then 
  echo "AllowUsers $ADMIN_USER" >> "$SSHD_CONFIG"
else 
  sed -i "s/^#*AllowUsers.*/AllowUsers $ADMIN_USER/" "$SSHD_CONFIG"
fi

# Validate sshd config before restarting to prevent lockout
sshd -t -f "$SSHD_CONFIG" || { echo "❌ sshd config invalid, restoring backup"; cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"; exit 1; }

# Reload SSH using whichever unit exists on this distro image.
if systemctl cat ssh.service >/dev/null 2>&1; then
  systemctl reload-or-restart ssh
elif systemctl cat sshd.service >/dev/null 2>&1; then
  systemctl reload-or-restart sshd
else
  echo "❌ CRITICAL: Could not find ssh.service or sshd.service on this host."
  exit 1
fi

echo "Configuring Fail2Ban..."
cat << 'EOF' > /etc/fail2ban/jail.local
[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 3600
EOF
systemctl restart fail2ban

# 5. UFW Firewall Setup & DOCKER-USER rules (IPv4 + IPv6)
echo "Configuring UFW Firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Rate limit SSH globally
ufw limit ssh

# Backstop loopback gateway port explicit denial
echo "Adding loopback backstop defense for Gateway port $GATEWAY_PORT..."
ufw deny $GATEWAY_PORT/tcp comment 'OpenClaw gateway - loopback only. NOTE: Docker -p bypasses UFW INPUT; DOCKER-USER DROP is the real container backstop.'

# Allow Tailscale interface traffic proactively
if ip link show tailscale0 > /dev/null 2>&1; then
    ufw allow in on tailscale0
    echo "Tailscale interface rules added."
else
    echo "⚠️ Tailscale interface not found yet. Make sure to bind over Tailscale Serve."
fi

# Docker UFW Integration: Insert before the final COMMIT in /etc/ufw/after.rules (IPv4)
echo "Patching UFW after.rules for Docker isolation (IPv4)..."
if ! grep -q ":DOCKER-USER" /etc/ufw/after.rules; then
# Use awk to inject ONLY the rules block right before the last COMMIT line of the file.
# We do NOT inject a new *filter header inside the existing *filter block.
TMPFILE=$(mktemp /root/after.rules.tmp.XXXXXX)
awk '
/^COMMIT/ && !inserted {
    print ":DOCKER-USER - [0:0]"
    # DOCKER-USER filters traffic *destined for containers*.
    # These rules isolate container traffic. (Host traffic like SSH goes via INPUT).
    print "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
    print "-A DOCKER-USER -s 127.0.0.0/8 -j RETURN"
    print "-A DOCKER-USER -s 10.0.0.0/8 -j RETURN"
    print "-A DOCKER-USER -s 172.16.0.0/12 -j RETURN"
    print "-A DOCKER-USER -s 192.168.0.0/16 -j RETURN"
    print "-A DOCKER-USER -s 100.64.0.0/10 -j RETURN"
    print "-A DOCKER-USER -j DROP"
    inserted = 1
}
{ print }
' /etc/ufw/after.rules > "$TMPFILE" && mv "$TMPFILE" /etc/ufw/after.rules
fi

# Docker UFW Integration: Insert before the final COMMIT in /etc/ufw/after6.rules (IPv6)
echo "Patching UFW after6.rules for Docker isolation (IPv6)..."
if [ -f /etc/ufw/after6.rules ] && ! grep -q ":DOCKER-USER" /etc/ufw/after6.rules; then
TMPFILE6=$(mktemp /root/after6.rules.tmp.XXXXXX)
awk '
/^COMMIT/ && !inserted {
    print ":DOCKER-USER - [0:0]"
    # DOCKER-USER IPv6 container isolation
    print "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
    print "-A DOCKER-USER -s ::1/128 -j RETURN"
    print "-A DOCKER-USER -s fc00::/7 -j RETURN"
    print "-A DOCKER-USER -j DROP"
    inserted = 1
}
{ print }
' /etc/ufw/after6.rules > "$TMPFILE6" && mv "$TMPFILE6" /etc/ufw/after6.rules
fi

ufw --force enable
# Removed redundant ufw reload

# 6. Nightly Security Audit Script Deployment & Lock
echo "Deploying nightly security audit script..."
TARGET_AUDIT_SCRIPT="$OC_STATE_DIR/workspace/scripts/nightly-security-audit.sh"

if [ -f "$AUDIT_SCRIPT_SOURCE" ]; then
    # Ensure it is mutable before overwrite, if it already exists from a previous run
    if [ -f "$TARGET_AUDIT_SCRIPT" ]; then
        chattr -i "$TARGET_AUDIT_SCRIPT" || { echo "❌ Could not remove immutable bit from audit script. Aborting."; exit 1; }
    fi
    cp "$AUDIT_SCRIPT_SOURCE" "$TARGET_AUDIT_SCRIPT"
    echo "Audit script deployed to $TARGET_AUDIT_SCRIPT"
else
    echo "❌ CRITICAL: Source audit script ($AUDIT_SCRIPT_SOURCE) not found. Could not deploy."
    exit 1
fi

# 7. Finalize Ownership & Generate Baseline Hashing
echo "Applying final strict directory ownership and generating config baseline..."

# Final ownership sweep - covers all files written throughout the script
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OC_STATE_DIR"
# Re-apply permissions that chown -R doesn't touch
chmod 700 "$OC_STATE_DIR"
chmod 700 "$OC_STATE_DIR/workspace"
chmod 700 "$OC_STATE_DIR/workspace/scripts"
chmod 700 "$OC_STATE_DIR/devices"
chmod 700 "$TARGET_AUDIT_SCRIPT"
chmod 700 "$OC_STATE_DIR/security-baselines"
chmod 600 "$OC_STATE_DIR/openclaw.json"
chmod 600 "$OC_STATE_DIR/devices/paired.json"

# Lock immutable only after ownership is correct
chattr +i "$TARGET_AUDIT_SCRIPT" || echo "⚠️ Could not apply chattr +i to audit script. Is FS supported?"

# Generate config hash immediately using a specific bash login since the user has no interactive shell
echo "Generating SHA256 baseline check for secure config..."
su -s /bin/bash - "$OPENCLAW_USER" -c "sha256sum ~/.openclaw/openclaw.json > ~/.openclaw/.config-baseline.sha256 && chmod 600 ~/.openclaw/.config-baseline.sha256"

echo "✅ VM Security Setup completed."
echo "--------------------------------------------------------"
echo "Next Steps:"
echo "0. (If not already installed) Install OpenClaw CLI for $OPENCLAW_USER."
echo "1. Switch to the OpenClaw service user: sudo -u $OPENCLAW_USER /bin/bash"
echo "2. Register the nightly audit cron inside OpenClaw:"
echo "   openclaw cron add --name \"nightly-security-audit\" --cron \"0 3 * * *\" --session \"isolated\" ..."
echo "3. Populate your LLM API keys in ~/.openclaw/openclaw.json using the config.yaml reference."
echo "4. Optional: Explicitly verify $OPENCLAW_USER has no host ssh keys or creds lying around in ~/.aws, ~/.ssh etc."
echo "5. Run 'openclaw security audit' to verify active compliance."
echo "6. Verify Docker isolation: 'sudo iptables -S DOCKER-USER' and 'sudo ip6tables -S DOCKER-USER'."
echo "7. SAFETY: Verify SSH login works as '$ADMIN_USER' in a new terminal before closing this root session."
echo "8. Login as $ADMIN_USER and onboard/install service:"
echo "   sudo -iu $ADMIN_USER"
echo "   openclaw onboard --install-daemon"
echo "9. Or open the TUI as $ADMIN_USER:"
echo "   openclaw tui"
echo "10. Docker gateway helper (runbook automation):"
echo "   ./openclaw-docker-helper.sh run"
echo "   ./openclaw-docker-helper.sh verify"
echo "   ./openclaw-docker-helper.sh tunnel-hint $ADMIN_USER <vps_ip>"
echo "   ./openclaw-docker-helper.sh devices-list"
echo "   ./openclaw-docker-helper.sh devices-approve <UUID>"
echo "--------------------------------------------------------"
