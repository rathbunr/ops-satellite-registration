# Satellite Pre-Registration Bootstrap

Prepares hosts for Red Hat Satellite registration when they lack DNS access to the Satellite server. This playbook runs **before** the `redhat.satellite` collection is involved and uses only `ansible.builtin` modules — no external dependencies.

## The Problem

In many environments, newly provisioned or isolated hosts cannot resolve the Satellite server's FQDN because they don't yet have DNS access. Without name resolution, the registration curl command fails before it starts. Additionally, Satellite Remote Execution (REX) requires an SSH-accessible user account with the Satellite's foreman-proxy public key already deployed — a chicken-and-egg problem since the registration command that normally handles REX setup can't run until connectivity is established.

This playbook solves both problems in a single run.

## What It Does

The playbook executes six phases in order. Each phase is idempotent and safe to re-run.

**Phase 1 — DNS Resolution**
Adds the Satellite server's IP and FQDN to `/etc/hosts` using `blockinfile` with managed markers. Verifies resolution with `getent hosts` immediately after. Supports optional extra entries for future Capsule servers if your environment grows.

**Phase 2 — CA Certificate Trust**
Installs the Satellite's CA certificate into the system trust store so HTTPS connections to the Satellite are trusted. Two delivery methods are available:

- **Push** (default) — Copies the cert from the Ansible controller to each host. Requires you to place the cert file in your project once.
- **Pull** — Each host downloads the cert directly from the Satellite's `/pub` endpoint. The initial fetch uses `validate_certs: false` since the host doesn't trust the cert yet; every subsequent HTTPS call validates normally.

After installation, the playbook runs `update-ca-trust extract` and verifies the trust chain by making a validated HTTPS request to the Satellite.

**Phase 3 — REX User Account**
Creates a dedicated system user for Satellite Remote Execution. The UID is pinned to a consistent value across your fleet (configurable). This is the account Satellite will SSH into when running remote jobs.

**Phase 4 — SSH Key Deployment**
Deploys the Satellite's `foreman-proxy` SSH public key into the REX user's `authorized_keys`. This is how REX authenticates — Satellite's foreman-proxy process SSHes to managed hosts using this keypair. No passwords are involved in REX authentication.

**Phase 5 — Sudo Configuration**
Creates a validated sudoers drop-in file granting the REX user the privileges Satellite needs to execute jobs. Defaults to passwordless sudo for all commands (Satellite's standard expectation). The sudoers file is validated with `visudo -cf` before being written.

**Phase 6 — SSHD Hardening**
Ensures `PubkeyAuthentication yes` is set in sshd_config. Validates the config with `sshd -t` before restarting the service.

## Prerequisites

### On the Ansible Controller / AAP

- SSH and sudo access to the target hosts (Machine credential in AAP).
- The Satellite CA certificate file (for push method). Obtain it from your Satellite:

```bash
# Option A: Copy directly from the Satellite filesystem
scp root@satellite.example.com:/etc/pki/katello/certs/katello-server-ca.crt files/

# Option B: Download from the Satellite's public endpoint
curl -k https://satellite.example.com/pub/katello-server-ca.crt -o files/katello-server-ca.crt
```

- The foreman-proxy SSH public key. Obtain it from your Satellite:

```bash
ssh root@satellite.example.com cat /usr/share/foreman-proxy/.ssh/id_rsa_foreman_proxy.pub
```

### On the Satellite Server

After running this bootstrap, configure the Satellite to use the REX user you created:

1. Navigate to **Administer → Settings → Remote Execution**.
2. Set `remote_execution_ssh_user` to match your `satellite_rex_user` value (default: `foreman-rex`).
3. Ensure the Satellite's SSH key matches what you deployed. Verify at **Infrastructure → Smart Proxies → your proxy → Actions → Refresh**.

## Project Structure

```
satellite-bootstrap/
├── README.md
├── satellite_bootstrap.yml         ← standalone bootstrap playbook
├── satellite_full_onboard.yml      ← chains bootstrap → registration
└── group_vars/
    └── all/
        └── bootstrap.yml           ← all configurable variables
```

## Configuration

All variables live in `group_vars/all/bootstrap.yml`. The critical ones to update for your environment:

| Variable | Description | Example |
|---|---|---|
| `satellite_fqdn` | Satellite server's fully qualified domain name | `satellite.example.com` |
| `satellite_ip` | Satellite server's IP address | `10.0.1.50` |
| `satellite_ca_delivery` | How to deliver the CA cert: `push` or `pull` | `push` |
| `satellite_ca_cert_local_path` | Path to the cert on the controller (push method) | `files/katello-server-ca.crt` |
| `satellite_rex_user` | Username for the REX service account | `foreman-rex` |
| `satellite_rex_ssh_pubkey` | The foreman-proxy SSH public key (full string) | `ssh-rsa AAAA...` |
| `satellite_rex_sudo_commands` | Sudo command scope | `ALL` |
| `satellite_rex_sudo_nopasswd` | Whether sudo requires a password | `true` |

### Securing Sensitive Values

The `satellite_rex_ssh_pubkey` value can be vault-encrypted:

```bash
ansible-vault encrypt_string 'ssh-rsa AAAA...' --name satellite_rex_ssh_pubkey
```

Paste the encrypted block into `group_vars/all/bootstrap.yml` in place of the plaintext value.

## Usage

### Standalone (CLI)

```bash
# Bootstrap only
ansible-playbook satellite_bootstrap.yml \
  -i inventory.yml \
  --become

# Full onboard (bootstrap + registration)
ansible-playbook satellite_full_onboard.yml \
  -i inventory.yml \
  --become \
  -e satellite_server_url=https://satellite.example.com \
  -e satellite_username=admin \
  -e @vault.yml --ask-vault-pass
```

### AAP 2.7

**Option A — Single Job Template**
Use `satellite_full_onboard.yml` as the playbook. Attach both a Machine credential (SSH access) and a Red Hat Satellite 6 credential (for the registration plays). The bootstrap phases only need the Machine credential; the registration phases use the Satellite credential.

**Option B — Workflow Template (recommended)**
Create two Job Templates and chain them in a Workflow:

```
[ Bootstrap ]  ──success──▶  [ Register Hosts ]
     │                              │
     └──failure──▶ [Notify]         └──failure──▶ [Notify]
```

This gives you separate success/failure handling per stage — if bootstrap succeeds but registration fails, you know DNS and trust are fine and can troubleshoot the Satellite API side independently.

| Workflow Node | Playbook | Credentials |
|---|---|---|
| Bootstrap | `satellite_bootstrap.yml` | Machine |
| Register Hosts | `satellite_register_hosts.yml` | Machine + Red Hat Satellite 6 |

## Verifying the Bootstrap

After running the playbook, you can verify each phase worked from any target host:

```bash
# Phase 1 — DNS
getent hosts satellite.example.com

# Phase 2 — CA trust
openssl s_client -connect satellite.example.com:443 -CApath /etc/pki/tls/certs/ < /dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)

# Phase 3 — REX user
id foreman-rex

# Phase 4 — SSH key
cat /home/foreman-rex/.ssh/authorized_keys

# Phase 5 — Sudo
sudo -l -U foreman-rex

# Phase 6 — SSHD
sshd -T | grep pubkeyauthentication
# Expected: pubkeyauthentication yes
```

## Extending for Capsules

If your environment later adds Capsule servers, add their entries to `satellite_extra_hosts_entries` in `group_vars/all/bootstrap.yml`:

```yaml
satellite_extra_hosts_entries:
  - ip: "10.0.2.60"
    fqdn: "capsule01.example.com"
    aliases:
      - capsule01
  - ip: "10.0.3.70"
    fqdn: "capsule02.example.com"
```

Each Capsule has its own foreman-proxy SSH key. If hosts register through a Capsule rather than directly, you would deploy that Capsule's public key instead of (or in addition to) the Satellite's key. That scenario would require a separate variable per Capsule or a lookup against the Capsule's API.

## Troubleshooting

**Phase 2 fails — HTTPS verification error after installing the cert**
The CA cert file may be incomplete or the wrong file. Verify it on the controller:
```bash
openssl x509 -in files/katello-server-ca.crt -text -noout | head -20
```
Ensure the `Issuer` and `Subject` reference your Satellite's hostname.

**Phase 4 fails — `authorized_key` module errors**
If `ansible.posix` is not in your execution environment, the playbook falls back to `ansible.builtin.authorized_key`. Ensure the REX user's home directory exists and has correct ownership (`satellite_rex_create_home: true` handles this).

**REX jobs fail after registration**
Confirm the Satellite's `remote_execution_ssh_user` setting matches `satellite_rex_user`. In the Satellite UI: Administer → Settings → Remote Execution. The user must match exactly.
