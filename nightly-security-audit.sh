#!/usr/bin/env bash
# OpenClaw Minimalist Security Practice Guide v2.7 - Nightly Comprehensive Security Audit Script
# Covers 13 core metrics; DR failure does not block audit reporting

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
OC="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
REPORT_DIR="/tmp/openclaw/security-reports"
mkdir -p "$REPORT_DIR"

DATE_STR=$(date +%F)
REPORT_FILE="$REPORT_DIR/report-$DATE_STR.txt"
SUMMARY="🛡️ OpenClaw Daily Security Audit Report ($DATE_STR)\n\n"

echo "=== OpenClaw Security Audit Detailed Report ($DATE_STR) ===" > "$REPORT_FILE"

append_warn() {
  SUMMARY+="$1\n"
}

# 1) OpenClaw Base Audit
echo "[1/13] OpenClaw Base Audit (--deep)" >> "$REPORT_FILE"
if openclaw security audit --deep >> "$REPORT_FILE" 2>&1; then
  SUMMARY+="1. Platform Audit: ✅ Native scan executed\n"
else
  append_warn "1. Platform Audit: ⚠️ Execution failed (see detailed report)"
fi

# 2) Process & Network
echo -e "\n[2/13] Listening Ports & High Resource Processes" >> "$REPORT_FILE"
ss -tunlp >> "$REPORT_FILE" 2>/dev/null || true
top -b -n 1 | head -n 15 >> "$REPORT_FILE" 2>/dev/null || true
SUMMARY+="2. Process Network: ✅ Captured listening ports & process snapshot\n"

# 3) Sensitive Directory Changes
echo -e "\n[3/13] Modified files in last 24h" >> "$REPORT_FILE"
MOD_FILES=$(find "$OC" /etc ~/.ssh ~/.gnupg /usr/local/bin -type f -mtime -1 2>/dev/null | wc -l | xargs)
echo "Total modified files: $MOD_FILES" >> "$REPORT_FILE"
SUMMARY+="3. Directory Changes: ✅ $MOD_FILES files (in /etc/ or ~/.ssh, etc.)\n"

# 4) System Scheduled Tasks
echo -e "\n[4/13] System-level Cron & Systemd Timers" >> "$REPORT_FILE"
ls -la /etc/cron.* /var/spool/cron/crontabs/ >> "$REPORT_FILE" 2>/dev/null || true
systemctl list-timers --all >> "$REPORT_FILE" 2>/dev/null || true
if [ -d "$HOME/.config/systemd/user" ]; then
  ls -la "$HOME/.config/systemd/user" >> "$REPORT_FILE" 2>/dev/null || true
fi
SUMMARY+="4. System Cron: ✅ Captured system-level scheduled tasks\n"

# 5) OpenClaw Cron Jobs
echo -e "\n[5/13] OpenClaw Cron Jobs" >> "$REPORT_FILE"
if openclaw cron list >> "$REPORT_FILE" 2>&1; then
  SUMMARY+="5. Local Cron: ✅ Pulled internal task list\n"
else
  append_warn "5. Local Cron: ⚠️ Pull failed (possible token/permission issue)"
fi

# 6) Logins & SSH Audit
echo -e "\n[6/13] Recent Logins & Failed SSH Attempts" >> "$REPORT_FILE"
last -a -n 5 >> "$REPORT_FILE" 2>/dev/null || true
FAILED_SSH=0
if command -v journalctl >/dev/null 2>&1; then
  FAILED_SSH=$(journalctl -u sshd --since "24 hours ago" 2>/dev/null | grep -Ei "Failed|Invalid" | wc -l | xargs)
fi
if [ "$FAILED_SSH" = "0" ]; then
  for LOGF in /var/log/auth.log /var/log/secure /var/log/messages; do
    if [ -f "$LOGF" ]; then
      FAILED_SSH=$(grep -Ei "sshd.*(Failed|Invalid)" "$LOGF" 2>/dev/null | tail -n 1000 | wc -l | xargs)
      break
    fi
  done
fi
echo "Failed SSH attempts (recent): $FAILED_SSH" >> "$REPORT_FILE"
SUMMARY+="6. SSH Security: ✅ $FAILED_SSH failed attempts in last 24h\n"

# 7) Critical File Integrity & Permissions
echo -e "\n[7/13] Critical Config Permissions & Hash Baseline" >> "$REPORT_FILE"
HASH_RES="MISSING_BASELINE"
if [ -f "$OC/.config-baseline.sha256" ]; then
  HASH_RES=$(cd "$OC" && sha256sum -c .config-baseline.sha256 2>&1 || true)
fi
echo "Hash Check: $HASH_RES" >> "$REPORT_FILE"
PERM_OC=$(stat -c "%a" "$OC/openclaw.json" 2>/dev/null || echo "MISSING")
PERM_PAIRED=$(stat -c "%a" "$OC/devices/paired.json" 2>/dev/null || echo "MISSING")
PERM_SSHD=$(stat -c "%a" /etc/ssh/sshd_config 2>/dev/null || echo "N/A")
PERM_AUTH_KEYS=$(stat -c "%a" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "N/A")
echo "Permissions: openclaw=$PERM_OC, paired=$PERM_PAIRED, sshd_config=$PERM_SSHD, authorized_keys=$PERM_AUTH_KEYS" >> "$REPORT_FILE"
if [[ "$HASH_RES" == *"OK"* ]] && [[ "$PERM_OC" == "600" ]]; then
  SUMMARY+="7. Config Baseline: ✅ Hash check passed and permissions compliant\n"
else
  append_warn "7. Config Baseline: ⚠️ Baseline missing/invalid or permissions non-compliant"
fi

# 8) Yellow Line Audit (sudo logs vs memory)
echo -e "\n[8/13] Yellow Line Cross-Validation (sudo logs vs memory)" >> "$REPORT_FILE"
SUDO_COUNT=0
for LOGF in /var/log/auth.log /var/log/secure /var/log/messages; do
  if [ -f "$LOGF" ]; then
    SUDO_COUNT=$(grep -Ei "sudo.*COMMAND" "$LOGF" 2>/dev/null | tail -n 2000 | wc -l | xargs)
    break
  fi
done
MEM_FILE="$OC/workspace/memory/$DATE_STR.md"
MEM_COUNT=$(grep -i "sudo" "$MEM_FILE" 2>/dev/null | wc -l | xargs)
echo "Sudo Logs(recent): $SUDO_COUNT, Memory Logs(today): $MEM_COUNT" >> "$REPORT_FILE"
SUMMARY+="8. Yellow Line Audit: ✅ sudo records=$SUDO_COUNT, memory records=$MEM_COUNT\n"

# 9) Disk Usage
echo -e "\n[9/13] Disk Usage & Recent Large Files" >> "$REPORT_FILE"
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
LARGE_FILES=$(find / -xdev -type f -size +100M -mtime -1 2>/dev/null | wc -l | xargs)
echo "Disk Usage: $DISK_USAGE, Large Files (>100M): $LARGE_FILES" >> "$REPORT_FILE"
SUMMARY+="9. Disk Capacity: ✅ Root partition usage $DISK_USAGE, $LARGE_FILES new large files\n"

# 10) Gateway Environment Variables
echo -e "\n[10/13] Gateway Env Var Leak Scan" >> "$REPORT_FILE"
GW_PID=$(pgrep -f "openclaw-gateway" | head -n 1 || true)
if [ -n "$GW_PID" ] && [ -r "/proc/$GW_PID/environ" ]; then
  strings "/proc/$GW_PID/environ" | grep -iE 'SECRET|TOKEN|PASSWORD|KEY' | awk -F= '{print $1"=(Hidden)"}' >> "$REPORT_FILE" 2>/dev/null || true
  SUMMARY+="10. Env Vars: ✅ Executed gateway process sensitive variable scan\n"
else
  append_warn "10. Env Vars: ⚠️ Could not locate openclaw-gateway process"
fi

# 11) DLP (Plaintext Credential Scan)
echo -e "\n[11/13] Plaintext Private Key/Mnemonic Leak Scan (DLP)" >> "$REPORT_FILE"
SCAN_ROOT="$OC/workspace"
DLP_HITS=0
if [ -d "$SCAN_ROOT" ]; then
  # ETH private key-ish: 0x + 64 hex
  H1=$(grep -RInE --exclude-dir=.git --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' '\b0x[a-fA-F0-9]{64}\b' "$SCAN_ROOT" 2>/dev/null | wc -l | xargs)
  # 12/24-word mnemonic-ish (rough heuristic)
  H2=$(grep -RInE --exclude-dir=.git --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' '\b([a-z]{3,12}\s+){11}([a-z]{3,12})\b|\b([a-z]{3,12}\s+){23}([a-z]{3,12})\b' "$SCAN_ROOT" 2>/dev/null | wc -l | xargs)
  DLP_HITS=$((H1 + H2))
fi
echo "DLP hits (heuristic): $DLP_HITS" >> "$REPORT_FILE"
if [ "$DLP_HITS" -gt 0 ]; then
  append_warn "11. Sensitive Credential Scan: ⚠️ Detected $DLP_HITS potential plaintext secrets, please review manually"
else
  SUMMARY+="11. Sensitive Credential Scan: ✅ No obvious private key/mnemonic patterns found\n"
fi

# 12) Skill/MCP Integrity (Baseline Diff)
echo -e "\n[12/13] Skill/MCP Integrity Baseline Diff" >> "$REPORT_FILE"
SKILL_DIR="$OC/workspace/skills"
MCP_DIR="$OC/workspace/mcp"
HASH_DIR="$OC/security-baselines"
mkdir -p "$HASH_DIR"
CUR_HASH="$HASH_DIR/skill-mcp-current.sha256"
BASE_HASH="$HASH_DIR/skill-mcp-baseline.sha256"
: > "$CUR_HASH"
for D in "$SKILL_DIR" "$MCP_DIR"; do
  if [ -d "$D" ]; then
    find "$D" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null >> "$CUR_HASH" || true
  fi
done
if [ -s "$CUR_HASH" ]; then
  if [ -f "$BASE_HASH" ]; then
    if diff -u "$BASE_HASH" "$CUR_HASH" >> "$REPORT_FILE" 2>&1; then
      SUMMARY+="12. Skill/MCP Baseline: ✅ Consistent with previous baseline\n"
    else
      append_warn "12. Skill/MCP Baseline: ⚠️ Detected file hash changes (see diff)"
    fi
  else
    cp "$CUR_HASH" "$BASE_HASH"
    SUMMARY+="12. Skill/MCP Baseline: ✅ Initial baseline generated\n"
  fi
else
  SUMMARY+="12. Skill/MCP Baseline: ✅ No skills/mcp directory files found\n"
fi

# 13) Disaster Recovery Brain Backup (Does not block)
echo -e "\n[13/13] Disaster Recovery Brain Backup (Git Backup)" >> "$REPORT_FILE"
BACKUP_STATUS=""
if [ -d "$OC/.git" ]; then
  (
    cd "$OC" || exit 1
    git add . >> "$REPORT_FILE" 2>&1 || true
    if git diff --cached --quiet; then
      echo "No staged changes" >> "$REPORT_FILE"
      BACKUP_STATUS="skip"
    else
      if git commit -m "🛡️ Nightly brain backup ($DATE_STR)" >> "$REPORT_FILE" 2>&1 && git push origin main >> "$REPORT_FILE" 2>&1; then
        BACKUP_STATUS="ok"
      else
        BACKUP_STATUS="fail"
      fi
    fi
  )
else
  BACKUP_STATUS="nogit"
fi

case "$BACKUP_STATUS" in
  ok)   SUMMARY+="13. DR Backup: ✅ Automatically pushed to remote repository\n" ;;
  skip) SUMMARY+="13. DR Backup: ✅ No new changes, skipped push\n" ;;
  nogit) append_warn "13. DR Backup: ⚠️ Git repository not initialized, skipped" ;;
  *)    append_warn "13. DR Backup: ⚠️ Push failed (does not affect scan report)" ;;
esac

echo -e "$SUMMARY\n📝 Detailed report saved locally: $REPORT_FILE"
exit 0
