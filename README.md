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

## 2) Choose one setup path

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

### Path B: Ansible (recommended for repeatable runs)

From your local machine:

```bash
cd openclaw-vm-setup
```

Edit `ansible/inventory.ini`:

```ini
[openclaw]
vps ansible_host=YOUR_SERVER_IP
```

## 3) Vault secrets (Ansible path)

Create vault file:

```bash
cp ansible/group_vars/vault.yml.example ansible/group_vars/vault.yml
ansible-vault edit ansible/group_vars/vault.yml
```

Put this in `ansible/group_vars/vault.yml`:

```yaml
vault_tailscale_auth_key: "tskey-..."
vault_openclaw_gateway_token: "long-random-token"
```

What is Vault password?
- It is the password you choose when encrypting/editing `vault.yml`.
- It encrypts/decrypts secrets in that file.
- You must provide it when running playbook with `--ask-vault-pass`.

## 4) Run Ansible

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --syntax-check
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u root --check --diff --ask-vault-pass
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u root --ask-vault-pass
```

If you connect as non-root admin user:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml -u <admin_user> -b --ask-become-pass --ask-vault-pass
```

## 5) Finalize after first successful run

Open a new SSH terminal and verify login as your admin user first, then:

```bash
sudo -iu <admin_user>
openclaw onboard --install-daemon
# or
openclaw tui
```
