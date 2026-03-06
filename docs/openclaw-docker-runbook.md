# OpenClaw Docker Runbook

This runbook covers Docker-only access via loopback port publishing and SSH tunneling.

Helper script available in repo root:

```bash
./openclaw-docker-helper.sh run
./openclaw-docker-helper.sh verify
./openclaw-docker-helper.sh tunnel-hint <admin_user> <vps_ip>
./openclaw-docker-helper.sh devices-list
./openclaw-docker-helper.sh devices-approve <UUID>
```

## 1) Run OpenClaw gateway in Docker on loopback-only host port

On the VPS, run OpenClaw container with host port `2404` mapped to container port `18789`, bound to host loopback only:

```bash
docker run -d --name openclaw-gateway \
  -p 127.0.0.1:2404:18789 \
  ghcr.io/openclaw/openclaw:latest
```

Verify host binding:

```bash
ss -lntp | grep 2404
```

Expected host bind: `127.0.0.1:2404` (not `0.0.0.0:2404`).

## 2) Bind guidance: container `--bind lan`, host loopback publish

When running OpenClaw inside a container, use container-side bind mode `lan` so the process listens on container interfaces. Keep security at the host publish layer with `127.0.0.1:2404:18789`.

If using `docker compose`, equivalent port mapping is:

```yaml
ports:
  - "127.0.0.1:2404:18789"
```

## 3) Access from local machine using SSH tunnel

From your laptop:

```bash
ssh -L 2404:127.0.0.1:2404 <admin_user>@<vps_ip>
```

Then open:

```text
http://127.0.0.1:2404
```

No public firewall rule for `2404` is required.

## 4) OPENCLAW_GATEWAY_PORT workaround for container exec

If your Docker mapping uses `127.0.0.1:2404:18789`, keep `OPENCLAW_GATEWAY_PORT=18789` for commands executed inside the container.

Use:

```bash
docker compose exec -e OPENCLAW_GATEWAY_PORT=18789 openclaw-gateway node dist/index.js devices list
```

Do not pass `127.0.0.1:2404` to `OPENCLAW_GATEWAY_PORT` inside the container.

## 5) Device pairing approval flow

List pending device requests:

```bash
docker compose exec -e OPENCLAW_GATEWAY_PORT=18789 openclaw-gateway node dist/index.js devices list
```

Approve a pending device UUID:

```bash
docker compose exec -e OPENCLAW_GATEWAY_PORT=18789 openclaw-gateway node dist/index.js devices approve <UUID>
```

After approval, refresh the browser UI.

## Scope note

This runbook is for OpenClaw Docker gateway access and pairing flow. App-specific migrations (HellCoin, Tor service move, RangerChat migration) are outside this repo automation scope.

## Quick verify

Check container is running:

```bash
docker ps | grep openclaw-gateway
```

Expected: one running row for `openclaw-gateway`.

Check gateway host bind is loopback only:

```bash
ss -lntp | grep 2404
```

Expected: `127.0.0.1:2404` (not `0.0.0.0:2404`).

Check firewall state:

```bash
ufw status verbose
```

Expected: `Status: active` and no explicit allow rule for public `2404/tcp`.
