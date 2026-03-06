#!/usr/bin/env bash
# Helper for OpenClaw Docker gateway operations on a VPS.
# Covers loopback-only port publishing, verification, and device pairing CLI flow.

set -euo pipefail

HOST_PORT="${HOST_PORT:-2404}"
CONTAINER_PORT="${CONTAINER_PORT:-18789}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-gateway}"
IMAGE="${IMAGE:-ghcr.io/openclaw/openclaw:latest}"
SERVICE_NAME="${SERVICE_NAME:-openclaw-gateway}"

usage() {
  cat <<EOF
Usage:
  $0 run
  $0 verify
  $0 tunnel-hint <admin_user> <vps_ip>
  $0 devices-list
  $0 devices-approve <UUID>

Environment overrides:
  HOST_PORT (default: 2404)
  CONTAINER_PORT (default: 18789)
  CONTAINER_NAME (default: openclaw-gateway)
  IMAGE (default: ghcr.io/openclaw/openclaw:latest)
  SERVICE_NAME (default: openclaw-gateway)
EOF
}

run_gateway() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' already exists. Starting it..."
    docker start "$CONTAINER_NAME" >/dev/null || true
  else
    echo "Starting '$CONTAINER_NAME' with loopback-only mapping ${HOST_PORT}:${CONTAINER_PORT}..."
    docker run -d \
      --name "$CONTAINER_NAME" \
      -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
      "$IMAGE" >/dev/null
  fi

  echo "Gateway started."
  echo "Reminder: if container-side bind options are configurable, use '--bind lan' inside container and keep host publish loopback-only."
}

verify_gateway() {
  echo "== docker ps =="
  docker ps | grep "$CONTAINER_NAME" || echo "WARN: container '$CONTAINER_NAME' not currently running"

  echo
  echo "== socket bind =="
  ss -lntp | grep "$HOST_PORT" || echo "WARN: nothing listening on host port $HOST_PORT"

  echo
  echo "== ufw status =="
  ufw status verbose || true
}

tunnel_hint() {
  local admin_user="${1:-}"
  local vps_ip="${2:-}"
  if [[ -z "$admin_user" || -z "$vps_ip" ]]; then
    echo "Usage: $0 tunnel-hint <admin_user> <vps_ip>"
    exit 1
  fi

  cat <<EOF
Run this on your local machine:
ssh -L ${HOST_PORT}:127.0.0.1:${HOST_PORT} ${admin_user}@${vps_ip}

Then open:
http://127.0.0.1:${HOST_PORT}
EOF
}

devices_list() {
  echo "Trying docker compose exec first..."
  if docker compose exec -e OPENCLAW_GATEWAY_PORT="$CONTAINER_PORT" "$SERVICE_NAME" node dist/index.js devices list; then
    return 0
  fi

  echo "docker compose exec failed. Trying docker exec on '$CONTAINER_NAME'..."
  docker exec -e OPENCLAW_GATEWAY_PORT="$CONTAINER_PORT" "$CONTAINER_NAME" node dist/index.js devices list
}

devices_approve() {
  local uuid="${1:-}"
  if [[ -z "$uuid" ]]; then
    echo "Usage: $0 devices-approve <UUID>"
    exit 1
  fi

  echo "Trying docker compose exec first..."
  if docker compose exec -e OPENCLAW_GATEWAY_PORT="$CONTAINER_PORT" "$SERVICE_NAME" node dist/index.js devices approve "$uuid"; then
    return 0
  fi

  echo "docker compose exec failed. Trying docker exec on '$CONTAINER_NAME'..."
  docker exec -e OPENCLAW_GATEWAY_PORT="$CONTAINER_PORT" "$CONTAINER_NAME" node dist/index.js devices approve "$uuid"
}

cmd="${1:-}"
case "$cmd" in
  run)
    run_gateway
    ;;
  verify)
    verify_gateway
    ;;
  tunnel-hint)
    shift
    tunnel_hint "$@"
    ;;
  devices-list)
    devices_list
    ;;
  devices-approve)
    shift
    devices_approve "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
