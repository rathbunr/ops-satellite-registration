# AAP Container Registry & Proxy Troubleshooting Runbook

**Applies to:** Containerized AAP (validated on 2.7 lab / 2.6-11 work)
**Run as:** the install user (`svc_ansible` lab / `aap` work) on the controller node
**Symptom family:** job templates fail with EMPTY output; default EE image
pulls fail; `podman pull` reset-by-peer or SSL errors; registry login absent
after patch/upgrade cycles

**History:** This failure pattern recurred from AAP 2.4 era. Patch/upgrade
cycles can leave host registry auth missing/expired and/or reset default EE
registrations. Inventory syncs may keep working (their EE is locally cached)
while template jobs die at launch — do not let the working sync convince you
the registry is fine.

---

## Symptom decision table

| Symptom | Layer | Section |
|---|---|---|
| Template job: Failed, EMPTY stdout | Default EE pull at launch | 1, 3 |
| `podman login --get-login` → "not logged in" | Host auth absent | 1 |
| Login OK, `podman pull` reset-by-peer / curl error 35 | Network / proxy / TLS inspection | 2 |
| Login OK, CLI pull OK, template jobs still die empty | Controller's stored registry credential stale | 3 |
| Inventory sync works but templates don't | Sync EE locally cached; default EE is not | 1, 3 |

---

## 1 — Host registry authentication

```bash
# Current state (expect a service account string, e.g. 7630362|ansible-reg-svc):
podman login registry.redhat.io --get-login
```

If "not logged in" (or in doubt), log in fresh. Get a NEW token first —
tokens expire — from https://access.redhat.com/terms-based-registry/
(service account → regenerate token).

```bash
# Token via variable, stdin-fed: never in shell history, never in ps output.
# SINGLE QUOTES around the username are load-bearing — the pipe character
# otherwise splits the command and login silently never happens.
export REGISTRY_USERNAME='7630362|<service-account-name>'
read -s -p "Registry token: " REGISTRY_TOKEN; export REGISTRY_TOKEN; echo

printf '%s' "$REGISTRY_TOKEN" | podman login registry.redhat.io \
  -u "$REGISTRY_USERNAME" --password-stdin

# Verify auth AND the transfer path:
podman login registry.redhat.io --get-login
podman pull registry.redhat.io/ansible-automation-platform-26/ee-minimal-rhel9:latest
```

Pull succeeds → skip to section 3. Pull fails with login confirmed →
section 2.

Note: `~/.config/containers/auth.json` is bind-mounted into the platform
containers (verify with `podman inspect receptor --format '{{range
.Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'`), so host login
state propagates — but job-time pulls ALSO consult the controller's stored
registry credential (section 3). Both must be healthy.

---

## 2 — Network path / proxy diagnosis

Only needed when auth is confirmed but transfers fail (reset-by-peer,
curl error 35 / SSL connect error, stalls mid-blob).

**2.1 — What proxy config exists, at every layer podman consults:**

```bash
env | grep -iE '^(http_proxy|https_proxy|no_proxy)=' -i
grep -iE 'proxy' /etc/environment /etc/profile.d/*.sh 2>/dev/null
grep -riE 'proxy' /etc/containers/ ~/.config/containers/ 2>/dev/null
systemctl --user show-environment 2>/dev/null | grep -i proxy
```

**2.2 — Identify the reference architecture.** How does anything else on
this network reach Red Hat? Direct? Via corporate proxy? Via Satellite or a
local Automation Hub? Match the working pattern — if the site standard is an
internal hub/mirror, re-point the default EE registrations there (section 3
with the internal URL) instead of fighting for direct egress.

**2.3 — Isolate with explicit proxy on/off:**

```bash
# Direct, no proxy:
https_proxy= http_proxy= podman pull <image> 2>&1 | tail -5
# Through the corporate proxy:
https_proxy=http://<proxy>:<port> podman pull <image> 2>&1 | tail -5
```

**2.4 — TLS inspection check** (handshake failures / error 35):

```bash
openssl s_client -connect registry.redhat.io:443 </dev/null 2>/dev/null \
  | grep -E 'subject=|issuer='
```

Issuer = corporate CA → TLS interception. Either trust the corporate CA in
the container trust store, or (better) request inspection bypass /
allowlisting for registry.redhat.io AND its CDN endpoints. Identify the CDN
host taking the reset with:

```bash
podman pull --log-level=debug <image> 2>&1 | tail -30
```

Registry pulls are two-phase: auth/manifest against registry.redhat.io
(small), blobs redirected to CDN hosts (large). Firewalls frequently permit
the former and kill the latter — allowlist requests must include the CDN.

**2.5 — If a proxy is the fix, it must reach BOTH layers:**

- CLI podman: the install user's environment (persist in ~/.bashrc or
  /etc/profile.d)
- Job-time pulls: the platform containers — set the proxy vars in the
  containerized installer inventory and re-run the installer config;
  containers do NOT inherit the host shell environment
- Set `no_proxy` to cover localhost, the node FQDN, and the internal domain,
  or platform-internal traffic will try to transit the proxy and break

---

## 3 — Controller default EE registration

The controller stores its own registry credential on the default EE records.
`awx-manage` lives INSIDE the task container — running it on the host gives
"command not found".

```bash
# Confirm task container name (2.6/2.7 both use automation-controller-task):
podman ps --format '{{.Names}}' | grep -i task

# Verify subcommand + flags against THIS installed version before running:
podman exec -it automation-controller-task \
  awx-manage register_default_execution_environments --help
```

Verified flags on 2.7 (2026-07): `--registry-url`, `--registry-username`,
`--registry-password`, `--verify-ssl`. Idempotent: "creates or updates ...
if they are not yet created" — safe to re-run. Note from the help text: the
FIRST entry in DEFAULT_EXECUTION_ENVIRONMENTS is used for PROJECT UPDATES —
a broken default EE can therefore also break project syncs.

```bash
# With REGISTRY_USERNAME / REGISTRY_TOKEN still exported from section 1:
podman exec -it -e REGISTRY_USERNAME -e REGISTRY_TOKEN automation-controller-task \
  bash -c 'awx-manage register_default_execution_environments \
    --registry-url https://registry.redhat.io \
    --registry-username "$REGISTRY_USERNAME" \
    --registry-password "$REGISTRY_TOKEN" \
    --verify-ssl true'

unset REGISTRY_TOKEN
```

**UI alternative** (no CLI, supported path): Administration → Execution
Environments → edit each default EE → attach/update a Container Registry
credential (registry URL + username + token). Same registration the command
writes.

---

## 4 — Verification

1. `podman login registry.redhat.io --get-login` → service account shown
2. `podman pull <default-EE-image>` → completes
3. UI: Administration → Execution Environments → default EEs show the
   registry credential
4. Run a trivial job template (localhost debug playbook, default EE) →
   output renders (not empty) → template execution path healed
5. Re-run any template that previously died with empty output

---

## 5 — Post-patch checklist addition

After EVERY AAP patch/upgrade, before trusting the platform:

- [ ] `podman login registry.redhat.io --get-login` → service account, not
      "not logged in"
- [ ] `podman pull` one default EE image → completes
- [ ] Trivial job template run → non-empty output
- [ ] LDAP injection probe (`playbooks/probe-ldap-injection.yml`) → section
      [1] all present, section [3] SUCCESS
- [ ] Registry token expiry date recorded; renew before it lapses

---

## Appendix — Gotchas learned the hard way

- **Unquoted pipe in the username:** `podman login -u 7630362|name` pipes
  into a command called `name`; login silently never happens. Always single-
  quote the username.
- **awx-manage is container-only:** host-level invocation → "command not
  found". Wrap in `podman exec -it automation-controller-task ...`.
- **A working inventory sync proves nothing about the registry:** the sync's
  EE is locally cached; templates resolving the default EE hit the registry
  and die. Different EE resolution paths, different failure visibility.
- **curl 200 to /v2/ ≠ logged in:** that endpoint answers unauthenticated
  requests with a challenge. Reachability and auth are separate facts.
- **Reset-by-peer AFTER a 200 is normal:** middleboxes close with RST
  instead of FIN. Only resets that prevent completion matter.
- **Two credential stores:** host auth.json (CLI + cached-image refresh) and
  the controller's registry credential (job-time default EE pulls). Fixing
  one does not fix the other.
