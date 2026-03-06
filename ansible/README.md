# OpenClaw VM Ansible Bootstrap

This playbook converts the VM bootstrap flow from `setup-vm.sh` into idempotent Ansible roles.

## Run

```bash
cd vm-security-setup/ansible
ansible-playbook -i inventory.ini site.yml -u root
```

You can also pass variables non-interactively:

```bash
ansible-playbook -i inventory.ini site.yml -u root \
  -e "admin_user=markus" \
  -e "admin_ssh_public_key=ssh-ed25519 AAAA..." \
  -e "tailscale_auth_key=tskey-..."
```

## Notes

- `tailscale_auth_key` is optional.
- If `openclaw_gateway_token` is empty, the playbook generates one.
- After run, SSH is restricted to `admin_user` via `AllowUsers`.
- Final output reminds the admin to run:
  - `openclaw onboard --install-daemon`
  - `openclaw tui`
