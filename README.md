# ops_satellite-registration

Ansible automation for registering hosts with Red Hat Satellite 6.x, designed for AAP 2.7.

## Overview

This project provides two playbooks that handle the complete host registration lifecycle:

- **`satellite_bootstrap.yml`** — Pre-registration bootstrap using `ansible.builtin` only (no external collections). Prepares hosts that lack DNS access to the Satellite server by adding `/etc/hosts` entries, installing the Satellite CA certificate, creating a Remote Execution (REX) user, deploying the foreman-proxy SSH key, configuring sudo, and hardening sshd.

- **`satellite_register_hosts.yml`** — Registers hosts with Satellite using the `redhat.satellite` collection. Automatically resolves the correct activation key per host via a hierarchical fallback chain built from Ansible facts. Supports RHEL, CentOS, CentOS Stream, Rocky, Alma, and Oracle Linux out of the box.

- **`satellite_full_onboard.yml`** — Wrapper that chains bootstrap → registration in a single run.

## Project Structure

```
ops_satellite-registration/
├── satellite_bootstrap.yml
├── satellite_register_hosts.yml
├── satellite_full_onboard.yml
├── collections/
│   └── requirements.yml
├── files/
│   ├── katello-server-ca.crt          # .gitignore'd — provide per environment
│   └── .gitkeep
├── group_vars/
│   ├── all/
│   │   ├── bootstrap.yml
│   │   └── satellite.yml
│   ├── rhel7/satellite.yml
│   ├── rhel8/satellite.yml
│   └── rhel9/satellite.yml
├── inventory_example.yml
├── .gitignore
└── README.md
```

## Prerequisites

- Ansible Core 2.14+ or AAP 2.7
- `redhat.satellite` collection >= 5.11.0 (installed automatically via `collections/requirements.yml`)
- SSH + sudo access to target hosts
- A Red Hat Satellite 6.x server with activation keys configured

## One-Time Setup

### 1. Obtain the Satellite CA certificate

```bash
# On the Satellite server (stage to /tmp if root SSH is disabled)
sudo cp /etc/pki/katello/certs/katello-server-ca.crt /tmp/
sudo chmod 644 /tmp/katello-server-ca.crt

# From the controller
scp <user>@<satellite>:/tmp/katello-server-ca.crt files/
```

### 2. Obtain the foreman-proxy SSH public key

```bash
ssh <user>@<satellite>
sudo cat /usr/share/foreman-proxy/.ssh/id_rsa_foreman_proxy.pub
```

Paste the output into `group_vars/all/bootstrap.yml` as the `satellite_rex_ssh_pubkey` value.

### 3. Update variables

Edit `group_vars/all/bootstrap.yml`:
- `satellite_fqdn` — your Satellite server's FQDN
- `satellite_ip` — your Satellite server's IP
- `satellite_rex_ssh_pubkey` — the foreman-proxy public key

Edit `group_vars/all/satellite.yml`:
- `satellite_organization` — your Satellite organization name
- `satellite_location` — your Satellite location name
- `satellite_activation_key_map` — map OS versions to activation keys

## Activation Key Resolution

The registration playbook resolves activation keys using a hierarchical fallback chain built from each host's Ansible facts:

1. `{distro}_{major}.{minor}_{arch}` — e.g. `RedHat_9.4_x86_64`
2. `{distro}_{major}_{arch}` — e.g. `RedHat_9_x86_64`
3. `{distro}_{major}` — e.g. `RedHat_9`
4. `{family}_{major}.{minor}_{arch}` — alias (CentOS → RedHat)
5. `{family}_{major}_{arch}` — alias
6. `{family}_{major}` — alias
7. `default` — catch-all

For most environments, define one entry per RHEL major version (`RedHat_7`, `RedHat_8`, `RedHat_9`). Add specific entries only when a particular minor/arch combination needs different content (e.g. `RedHat_8.6_x86_64` for EUS).

Non-RHEL distributions are automatically mapped to the RedHat family via `satellite_distro_family_map`.

## Usage

### CLI (Testing)

```bash
# Set credentials
export SATELLITE_SERVER_URL=https://satellite.example.com
export SATELLITE_USERNAME=admin
read -sp 'Satellite admin password: ' SATELLITE_PASSWORD && export SATELLITE_PASSWORD
echo

# Bootstrap only
ansible-playbook satellite_bootstrap.yml \
  -i <target-fqdn>, \
  -u <ssh-user> \
  --become \
  --ask-pass \
  --ask-become-pass

# Registration only
ansible-playbook satellite_register_hosts.yml \
  -i <target-fqdn>, \
  -u <ssh-user> \
  --become \
  --ask-pass \
  --ask-become-pass

# Full onboard (both)
ansible-playbook satellite_full_onboard.yml \
  -i <target-fqdn>, \
  -u <ssh-user> \
  --become \
  --ask-pass \
  --ask-become-pass
```

> **Note:** The trailing comma after the hostname is required for ad-hoc inventory.

### AAP 2.7

**Project:** Point at this GitHub repo. AAP syncs collections from `collections/requirements.yml` automatically.

**Credentials:**
- *Red Hat Satellite 6* — injects `SATELLITE_SERVER_URL`, `SATELLITE_USERNAME`, `SATELLITE_PASSWORD` as environment variables
- *Machine* — SSH access to target hosts

**Recommended: Workflow Template (two nodes)**
1. Node 1: Job Template → `satellite_bootstrap.yml`
2. Node 2: Job Template → `satellite_register_hosts.yml` (runs on success of Node 1)

This gives independent failure handling per stage. Alternatively, use a single Job Template with `satellite_full_onboard.yml`.

## Tested With

- Red Hat Satellite 6.16+
- RHEL 9 target hosts
- AAP 2.7
- `redhat.satellite` collection 5.11.0+
