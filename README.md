# OpenClaw VM Setup

Run this from start to finish.

## 1) Clone repo

```bash
git clone https://github.com/markus-marandi/openclaw-vm-setup.git
cd openclaw-vm-setup
```

To update later:

```bash
git pull
```

## 2) Optional first step: Tailscale bootstrap

Run this before VM setup if you want Tailscale installed/authenticated first.

```bash
cd openclaw-vm-setup
bash tailscale-bootstrap.sh
```

With auth key:

```bash
bash tailscale-bootstrap.sh "tskey-..."
```

Without auth key, authenticate later with:

```bash
sudo tailscale up
```

Security note:
- Tailscale gives private tailnet access (including SSH) and does not make your services public on the internet by itself.
- Keep services bound to loopback/private interfaces and avoid opening public firewall ports unless you explicitly need public exposure.

## 3) Choose one setup path

Docker-only operational runbook (custom loopback port mapping, SSH tunnel, pairing):
`docs/openclaw-docker-runbook.md`

Scripted helper for the same flow:
`./openclaw-docker-helper.sh`

### Path A: Single script on the VPS (`setup-vm.sh`)

SSH to VPS as root, then run:

```bash
cd /root
git clone https://github.com/markus-marandi/openclaw-vm-setup.git
cd openclaw-vm-setup
bash setup-vm.sh <admin_user> "<admin_ssh_public_key>" "<tailscale_auth_key_optional>"
```

Example:

```bash
bash setup-vm.sh user "ssh-ed25519 AAAA... user@laptop" "tskey-..."
```

If your key is already in `/root/.ssh/authorized_keys`, you can omit arg #2:

```bash
bash setup-vm.sh <admin_user>
```

### Path B: Ansible (recommended for repeatable runs)

From your local machine:

```bash
cd openclaw-vm-setup
```

Set `ansible/inventory.ini` (this is a file edit, not a shell command):

```ini
[openclaw]
vps ansible_host=YOUR_SERVER_IP
```

Quick one-liner to write it:

```bash
cat > ansible/inventory.ini << 'EOF'
[openclaw]
vps ansible_host=46.62.239.12
EOF
```

If Ansible is missing (`ansible-playbook` or `ansible-vault: command not found`), install it first:

```bash
apt-get update
apt-get install -y ansible
```

## 4) Vault secrets (Ansible path)

Create vault file (must be encrypted before `ansible-vault edit`):

```bash
cp ansible/group_vars/vault.yml.example ansible/group_vars/vault.yml
ansible-vault encrypt ansible/group_vars/vault.yml
ansible-vault edit ansible/group_vars/vault.yml
```

If you already copied the file and got `input is not vault encrypted data`, run:

```bash
ansible-vault encrypt ansible/group_vars/vault.yml
ansible-vault edit ansible/group_vars/vault.yml
```

Put this in `ansible/group_vars/vault.yml` (both values are optional):

```yaml
vault_tailscale_auth_key: ""
vault_openclaw_gateway_token: ""
```

No tokens yet? That is fine:
- Empty `vault_openclaw_gateway_token` -> OpenClaw token is auto-generated on first run.
- Empty `vault_tailscale_auth_key` -> Tailscale install completes, auth is skipped.
- You can authenticate Tailscale later with browser flow:

```bash
sudo tailscale up
```

This prints a URL; open it and approve the machine in your tailnet.

What is Vault password?
- It is the password you choose when encrypting/editing `vault.yml`.
- It encrypts/decrypts secrets in that file.
- You must provide it when running playbook with `--ask-vault-pass`.

## 5) Run Ansible

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --syntax-check
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u root --check --diff --ask-vault-pass
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u root --ask-vault-pass
```

If you connect as non-root admin user:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u <admin_user> -b --ask-become-pass --ask-vault-pass
```

## 6) Finalize after first successful run

Open a new SSH terminal and verify login as your admin user first, then:

```bash
sudo -iu <admin_user>
openclaw onboard --install-daemon
# or
openclaw tui
```
