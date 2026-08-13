# Ansible Service Account Bootstrap

## Overview

This script creates a local service account (`svc_ansible_local`) on RHEL systems for two purposes:

1. **Initial AAP Access** — Provides Ansible Automation Platform (AAP) with password-based SSH access to newly provisioned systems that are not yet domain-joined. AAP uses this account to perform initial configuration, including Centrify client installation and Active Directory domain join. Once AAP connects, it exchanges its own SSH key automatically.

2. **Break-Glass Access** — After Centrify domain join completes and AD-based authentication becomes the primary access method, the local account remains as an emergency fallback. If AD connectivity is lost, Centrify fails, or the domain trust is broken, this account provides a recovery path that does not depend on external authentication infrastructure.

## Account Lifecycle

```
Phase 1: Bootstrap                    Phase 2: Steady State
┌──────────────────────┐              ┌──────────────────────┐
│ System provisioned   │              │ Centrify installed   │
│ No domain join       │              │ AD joined            │
│                      │              │                      │
│ svc_ansible_local    │──────────────│ AD accounts primary  │
│ = primary access     │  AAP installs│ svc_ansible_local    │
│ AAP connects via PW  │  Centrify &  │ = break-glass only   │
│ AAP exchanges SSH key│  AD joins    │ Password in vault    │
└──────────────────────┘              └──────────────────────┘
```

## Usage

```bash
# Copy to target system and run as root
sudo ./create_ansible_user.sh
```

The script will prompt for a password. This password is used by AAP for the initial connection and stored in a password vault for break-glass scenarios.

The script is idempotent — running it against a system where the account already exists will skip user creation and update the sudo configuration only.

## What the Script Creates

| Component | Configuration | Rationale |
|-----------|--------------|-----------|
| User account | `svc_ansible_local`, system account, `/bin/bash` shell | System account keeps UID below 1000, out of normal user range |
| Home directory | `/home/svc_ansible_local` | Required for SSH `authorized_keys` after AAP key exchange |
| Sudo | `NOPASSWD: ALL` via `/etc/sudoers.d/svc_ansible_local` | AAP requires privilege escalation for system configuration; break-glass requires sudo when AD/Centrify is unavailable |
| Password | Set interactively at creation | AAP initial connection; break-glass console access |

## What the Script Does NOT Create

| Component | Reason |
|-----------|--------|
| SSH authorized keys | AAP exchanges its own key on first connection — manual key deployment is unnecessary and creates key management overhead |
| Password aging | Break-glass accounts should not expire and lock out emergency access; compensating controls (vault storage, access logging) mitigate the risk |
| Login restrictions | Account must remain accessible when AD/Centrify is unavailable, which is the exact scenario requiring break-glass access |

## Security Considerations

- The account password must be stored in an enterprise password vault (CyberArk, Delinea, HashiCorp Vault, etc.) with appropriate access controls and audit logging.
- AAP Machine Credentials containing this password should use credential types that encrypt the password at rest and inject it at runtime.
- After Centrify domain join, this account should only be used when AD-based authentication is unavailable. Regular administrative access should use AD accounts with appropriate HBAC and sudo rules managed centrally.
- The `NOPASSWD` sudo configuration is intentional for this account. In a break-glass scenario, requiring a second authentication factor for privilege escalation defeats the purpose of emergency access when the authentication infrastructure is unavailable.
- Consider monitoring login events for this account via auditd or SIEM integration. Any non-emergency use should trigger review.

## Prerequisites

- RHEL 7, 8, 9, or 10
- Root access (direct or via sudo)
- AAP inventory entry for the target system with a Machine credential containing the account password

## Post-Execution Steps

1. Add the system to an AAP inventory
2. Create or assign a Machine credential with username `svc_ansible_local` and the password set during script execution
3. Run the Centrify installation and AD join playbook via AAP
4. Verify AD-based authentication works
5. Store the `svc_ansible_local` password in the enterprise password vault
6. Document the account in the system's authorization boundary inventory

---

## NIST 800-171 Rev 2 — System Security Plan Language

The following control implementation statements can be adapted for SSP documentation in CMMC Level 2 or NIST 800-171 assessments. Adjust organization name, system name, and specific tool references to match your environment.

---

### 3.1.1 — Authorized Access Control

> The organization limits system access to authorized users, processes acting on behalf of authorized users, and devices. A local service account (`svc_ansible_local`) is provisioned on each managed system for two authorized purposes: (1) initial system configuration by the Ansible Automation Platform (AAP) prior to Active Directory domain join, and (2) emergency break-glass access when centralized authentication services are unavailable. The account is created through a standardized, repeatable script that enforces consistent configuration across all managed systems. After Active Directory enrollment via Centrify, all routine administrative access uses centrally managed AD accounts. The local account password is stored in an enterprise password vault with access restricted to authorized system administrators.

### 3.1.2 — Limit System Access to Authorized Transactions and Functions

> System access via the local service account is limited to authorized functions. The account is used exclusively by AAP for automated system configuration (software installation, security hardening, compliance scanning) and as a break-glass recovery mechanism. The account is not used for routine administration, user-level tasks, or interactive sessions during normal operations. AAP job execution is logged, and all automation tasks are defined in version-controlled playbooks with change management oversight.

### 3.1.5 — Least Privilege

> The local service account is configured with elevated privileges (`NOPASSWD` sudo) limited to its two authorized use cases. This configuration is necessary because: (a) AAP requires root-equivalent access to perform system configuration, package installation, and security hardening; and (b) break-glass access must function when centralized privilege management (Centrify/AD) is unavailable. The risk of persistent elevated privileges is mitigated through compensating controls: the account password is vault-stored with restricted access, login events are monitored via auditd, and non-emergency use triggers security review. Routine administrative tasks are performed through AD accounts with least-privilege sudo rules managed centrally in the directory service.

### 3.1.7 — Prevent Non-Privileged Users from Executing Privileged Functions

> Privileged functions on managed systems are controlled through two mechanisms. During steady-state operations, Active Directory group membership and Centrify HBAC rules determine which users can execute privileged functions, enforcing separation of duties and least privilege. The local service account provides a secondary privileged access path restricted to the AAP service and authorized break-glass personnel. Access to the AAP platform is controlled through RBAC, and break-glass credentials are stored in a password vault with audited access. Both paths enforce authentication before privilege escalation.

### 3.5.1 — Identify System Users, Processes, and Devices

> The local service account is uniquely identified on each managed system as `svc_ansible_local` with a consistent system-level UID. The account is documented in the system authorization boundary inventory, and its purpose (AAP automation / break-glass) is recorded in the account description field. AAP job executions using this account are logged with the job template name, initiating user, timestamp, and target host, providing traceability from the privileged action back to the authorized user who initiated it.

### 3.5.2 — Authenticate Identities Before Allowing Access

> Authentication for the local service account uses two methods depending on the access path. AAP authenticates via SSH key exchange — upon initial connection with the account password, AAP deploys its managed SSH key and subsequently authenticates via public key cryptography. Break-glass access authenticates via the account password, which is stored in an enterprise password vault and subject to the vault's access controls and audit logging. Both methods require successful authentication before any system access is granted.

### 3.5.3 — Multifactor Authentication

> Multifactor authentication for privileged access is enforced at the AAP platform level, where administrators authenticate with organizational credentials and MFA before initiating automation jobs that utilize the local service account. The local account itself does not enforce MFA at the system level; this is a documented risk acceptance for the break-glass use case, as MFA infrastructure (AD, Centrify, network-based authenticators) may be unavailable during the exact scenarios requiring emergency access. This risk is mitigated through vault-stored credentials with restricted and audited access.

### 3.5.10 — Cryptographically Protected Passwords

> The local service account password is stored as a cryptographic hash on each managed system using the operating system's default password hashing algorithm (SHA-256 in FIPS mode). The password is stored in the enterprise password vault using the vault's encryption-at-rest capabilities. AAP Machine Credentials containing the password are encrypted at rest within the AAP database. After initial key exchange, AAP authenticates via SSH public key cryptography, eliminating password transmission during routine automation operations.

### 3.3.1 — System Audit Logging

> Login events for the local service account are captured by the system audit subsystem (auditd) and forwarded to the centralized log management solution. Successful and failed authentication attempts, privilege escalation events, and session activity are logged. Non-emergency use of the account triggers automated alerting for security review. AAP job executions are independently logged within the AAP platform with full traceability to the initiating user, job template, and execution output.
