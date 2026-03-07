# OpenClaw VM Ansible Bootstrap

This playbook converts the VM bootstrap flow from `setup-vm.sh` into idempotent Ansible roles.

## Run

```bash
cd ansible
ansible-playbook -i inventory.ini site.yml -u root --ask-vault-pass
```

You can also pass variables non-interactively:

```bash
ansible-playbook -i inventory.ini site.yml -u root \
  -e "admin_user=markus" \
  -e "admin_ssh_public_key=ssh-ed25519 AAAA..." \
  --ask-vault-pass
```

## Vault Secrets

Use Ansible Vault for sensitive values (`tailscale_auth_key`, `openclaw_gateway_token`):

```bash
cp group_vars/vault.yml.example group_vars/vault.yml
ansible-vault encrypt group_vars/vault.yml
ansible-vault edit group_vars/vault.yml
```

Populate these vault vars:

- `vault_tailscale_auth_key`
- `vault_openclaw_gateway_token`

If left empty, Tailscale auth is skipped and OpenClaw token is generated on first run.

Example with no tokens yet:

```yaml
vault_tailscale_auth_key: ""
vault_openclaw_gateway_token: ""
```

Later, on the VPS, you can authenticate Tailscale interactively:

```bash
sudo tailscale up
```

## Pinning

- `nodejs_major`: set to a major like `20` to use NodeSource and pin Node.js channel.
- `openclaw_version`: set to fixed version like `1.2.3` for deterministic install (default: `latest`).

## Notes

- If `openclaw_gateway_token` is empty, the playbook generates one.
- After run, SSH is restricted to `admin_user` via `AllowUsers`.
- Nightly audit cron is installed for `clawdbot` at `0 3 * * *` by default.
- Final output reminds the admin to run:
  - `openclaw onboard --install-daemon`
  - `openclaw tui`
