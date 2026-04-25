# VPS Server Management (Ansible)

Infrastructure-as-code for Ubuntu VPSs sitting behind Cloudflare, using
**one environment per VM**. Dedicated UAT and Prod VMs so you can upgrade
infrastructure (nginx, Postgres, LGTM stack) on UAT, validate, and
promote to Prod independently of application changes.

Ansible runs from a pinned Docker container — the only local
dependency is Docker itself. Ops endpoints (Grafana, Loki, Tempo) are
gated by **Tailscale**, not a public SSO proxy; the DNS records for
them resolve to a `100.x.x.x` Tailscale IP, invisible to anyone not on
your tailnet.

---

## Architecture at a glance

- **One env per VM.** UAT and Prod are separate VMs.
- **Multi-domain by default.** You declare a flat `domains:` list — every
  domain gets its own Cloudflare zone, its own cert lineage, and its
  own ops endpoints. No domain is treated as the "parent" of any other.
  Example with `domains = [example.com, example.org]`:
  - Prod VM serves `example.com`, `example.org`, `*.ops.example.com`,
    `*.ops.example.org`
  - UAT VM serves `uat.example.com`, `uat.example.org`,
    `*.ops.uat.example.com`, `*.ops.uat.example.org`
  - Same Grafana container, accessible at both `grafana.ops.<env>.example.com`
    and `grafana.ops.<env>.example.org` (nginx routes by Host header)
- **Ops endpoints are Tailscale-only.** Public DNS for them points at
  the VM's `100.x.x.x` Tailscale IP.
- **UAT apps are Tailscale-only too.** Public ports 80/443 stay closed
  on UAT; the apps serve only on the Tailscale interface. Public DNS
  for `uat.*` also points at the Tailscale IP.
- **Prod apps are public, behind Cloudflare.** ufw allows 80/443 only
  from Cloudflare CIDRs; the `origin_lockdown` role refreshes the
  allowlist on demand.
- **SSL via DNS-01.** Certbot uses the Cloudflare DNS API — wildcard
  certs work and renewal doesn't depend on public HTTP reachability.
  One cert lineage per Cloudflare zone.
- **Ansible in Docker.** `./ansible` wrapper builds + runs a pinned
  runner image. No local Python / pipx install.
- **Secrets.** `secrets.yml` is gitignored by default. Encrypt with
  `ansible-vault` if you want to commit it to your private fork, or
  keep it local-only and re-run `./ansible playbooks/site.yml`
  manually. The public template ships no CI workflows — add your own
  in your fork if you want push-to-deploy automation.

---

## Requirements

- **Workstation**: Docker (24+) and an SSH keypair (`~/.ssh/id_ed25519`).
- **VMs**: Ubuntu 24.04 (Noble), ~4 cores / 8 GB RAM / ~75 GB disk, one
  per environment. Root SSH must be enabled at first boot (it's
  disabled by the bootstrap playbook). Hetzner Cloud / DigitalOcean /
  etc. all work out of the box.
- **Cloudflare account** with DNS for your domains, and one API token
  per zone with `Zone:DNS:Edit` + `Zone:Firewall Services:Edit` scopes.
- **Tailscale account** (free solo plan is fine).
- **GitHub PAT** with `read:packages` so the VMs can pull private
  images from GHCR.

---

## Setup

### 1. Create a private fork

GitHub won't let you fork a public repo privately, so create an empty
private repo and push this template into it:

```bash
# On GitHub: create an empty private repo named e.g. vps-config-myproject.
# Do NOT initialize with a README, .gitignore, or license.

git clone --bare https://github.com/<your-org>/vps-config.git
cd vps-config.git
git push --mirror https://github.com/<you>/vps-config-myproject.git
cd .. && rm -rf vps-config.git

git clone https://github.com/<you>/vps-config-myproject.git
cd vps-config-myproject
git remote add upstream https://github.com/<your-org>/vps-config.git
```

Your fork owns `inventory/`, `secrets.yml`, and
`infrastructure/ssl.conf`. `upstream` delivers template updates.

### 2. Configure Cloudflare DNS

Add each of your domains to Cloudflare and point your registrar's
nameservers at the CF nameservers Cloudflare gave you. Then create the
records below per environment:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `ssh` (per env apex) | VM public IP | **DNS only** (grey) |
| A | Prod app domains (e.g. `@`, `www`, `@` on other zones) | Prod VM public IP | **Proxied** (orange) |
| A | Prod `ops.<apex>` wildcard (`*.ops`) | Prod VM **Tailscale** IP | **DNS only** (grey) |
| A | UAT app domains (e.g. `uat`) | UAT VM **Tailscale** IP | **DNS only** (grey) |
| A | UAT `ops.uat.<apex>` wildcard (`*.ops.uat`) | UAT VM **Tailscale** IP | **DNS only** (grey) |

Two important rules:

- **`ssh.<apex>` must be DNS-only** (grey cloud). SSH doesn't pass through
  the CF proxy; this record lets you bypass the proxy for SSH + Ansible
  connections.
- **Tailscale IPs can't be proxied.** Anything pointed at `100.x.x.x` has
  to be DNS-only (grey cloud) — CF won't accept the record as proxied.

> **Set CF SSL/TLS mode to "Full (strict)"** for each zone (dashboard →
> SSL/TLS → Overview). The `ssl` role issues real Let's Encrypt certs
> at the origin; Full (strict) validates them.

### 3. Mint API tokens

At <https://dash.cloudflare.com/profile/api-tokens> create **two tokens
per zone** (scoped independently for smaller blast radius):

- DNS token: `Zone:DNS:Edit` — used by certbot for the DNS-01 challenge.
- Firewall token: `Zone:Firewall Services:Edit` — used by the fail2ban
  CF ban action to push bans to IP Access Rules.

Restrict each token to its single zone under **Zone Resources →
Include → Specific zone → `<your-zone>`**. Referenced from `secrets.yml`
via whatever names you give them — the keys must match the
`dns_vault_key` / `firewall_vault_key` fields in `domains`
(`inventory/group_vars/all.yml`).

You'll also need a **Tailscale auth key** — at
<https://login.tailscale.com/admin/settings/keys> create one that is
*reusable* and *non-expiring* so your VMs don't need periodic re-auth.

And a **GitHub PAT** with `read:packages` if your app images live in
private GHCR repos.

### 4. Fill in inventory + vars + secrets

Copy each `.example` file and fill in:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/all.yml.example  inventory/group_vars/all.yml
cp inventory/group_vars/uat.yml.example  inventory/group_vars/uat.yml
cp inventory/group_vars/prod.yml.example inventory/group_vars/prod.yml
cp secrets.yml.example         secrets.yml
cp infrastructure/ssl.conf.example infrastructure/ssl.conf
```

Open each and edit:

- `inventory/hosts.yml` — set `ansible_host` to each VM's public IP.
- `inventory/group_vars/all.yml` — `admin_email`, the `domains` list
  (one entry per domain you operate, with `zone_id` and the two
  `*_vault_key` fields pointing at the token names in `secrets.yml`),
  `ops_subdomain`, and your `apps` list (name, image, port, whether
  they need DB / JWT, optional `subdomain` for service prefixes like
  `api.`).
- `inventory/group_vars/uat.yml` / `prod.yml` — usually no edits required.
- `secrets.yml` — all the random values + CF tokens + Tailscale auth
  key + GHCR creds + per-app DB/JWT secrets. Generate random values
  with `openssl rand -base64 30 | tr -d '=+/' | cut -c1-32` (passwords)
  or `openssl rand -hex 32` (JWT-shaped).
- `infrastructure/ssl.conf` — list every FQDN this VM serves, one per
  line. The first line under each zone is that zone's cert lineage
  primary.

> **Secrets handling.** `secrets.yml` is gitignored by default — keep
> it local-only, or run `./ansible --cmd ansible-vault encrypt secrets.yml`
> and commit the encrypted file to your private fork.

### 5. Bootstrap each VM (one-shot, as root)

The bootstrap playbook creates a `deploy` user with NOPASSWD sudo,
installs your SSH key, and disables root SSH + password auth.

```bash
./ansible playbooks/bootstrap.yml --limit uat
# Then, once UAT is up and you've walked through step 6–8:
./ansible playbooks/bootstrap.yml --limit prod
```

`bootstrap.yml` declares `remote_user: root` directly so no `-u` flag is
needed. From this point forward `site.yml` + `deploy_app.yml` connect
as `deploy`.

### 6. Provision the VM (site.yml)

Runs every role in order: base (OS / Docker) → tailscale → ssl →
postgres config → observability config → nginx + infra compose up →
fail2ban → origin_lockdown → apps.

```bash
./ansible playbooks/site.yml --limit uat
```

Takes ~10 minutes on a fresh VM. The Ansible output prints the
Tailscale IP near the end — create the matching DNS A records in CF
per step 2.

### 7. Verify

```bash
# SSH as deploy
ssh deploy@ssh.<infra-domain> 'docker ps'

# Tailscale should show the VM
tailscale status | grep <env>-vm

# SSL issued for each zone
ssh deploy@ssh.<infra-domain> 'ls /etc/letsencrypt/live/'

# Hit an ops endpoint from your Tailscale-connected laptop
curl -I https://grafana.ops.uat.example.com/
```

### 8. (Optional) Wire up CI in your fork

The public template ships no GitHub Actions workflows on purpose — pick
the automation that suits your fork. A common shape:

- a workflow on push to `main` that installs ansible, restores
  `secrets.yml` (vault-decrypt or paste-from-GH-secret), runs
  `ansible-playbook playbooks/site.yml --limit <env>`
- Trivy / Snyk image-scan workflow on a weekly schedule

Both can stay in your fork's `.github/workflows/`; the upstream
template won't try to fight you for them.

---

## Adding an app

1. Add an entry to `apps:` in `inventory/group_vars/all.yml`:

   ```yaml
   apps:
     - name: myapi
       base_domain: example.com               # must match a name in `domains`
       image: ghcr.io/<owner>/myapi:latest
       port: 8080
       needs_database: true
       needs_jwt: true
   ```

2. Add its secrets to `secrets.yml`:

   ```yaml
   myapi_db_password: <random>
   myapi_jwt_secret: <random-hex>
   ```

3. Update `infrastructure/ssl.conf` to include the app's FQDN (so
   certbot adds it to the zone's cert on the next run).

4. Deploy:

   ```bash
   ./ansible playbooks/site.yml --limit uat
   # or just this app:
   ./ansible playbooks/deploy_app.yml --limit uat -e apps_filter='["myapi"]'
   ```

The apps role idempotently creates the Postgres role + database (if
`needs_database`), renders `docker-compose.yml` + `.env` + nginx vhost
+ prometheus scrape target, pulls the image, and runs `docker compose
up -d`.

---

## Rotating secrets

Edit `secrets.yml` (or `ansible-vault edit secrets.yml`), re-run
`site.yml`. Every role that consumes a rotated value is idempotent — it
re-renders config files, restarts the affected container. DB password
rotations trigger an `ALTER ROLE` automatically.

---

## Upgrading the infra stack

Image pins live in `roles/nginx/defaults/main.yml`. Bump the tag you
want, re-run `site.yml --limit uat`, verify, then `--limit prod`.
The separation-per-env philosophy means you can break UAT without
affecting Prod users.

---

## Repository layout

```
vps-config/
├── ansible                          # Docker wrapper — `./ansible playbooks/site.yml ...`
├── docker/ansible.Dockerfile        # pinned ansible + collections image
├── ansible.cfg                      # inventory path, ssh settings
├── requirements.yml                 # Galaxy collections (baked into image)
├── inventory/
│   ├── hosts.yml.example            # copy → hosts.yml, fill in VM IPs
│   └── group_vars/
│       ├── all.yml.example          # shared config (domains, apps, CF zones)
│       ├── uat.yml.example          # env=uat posture (Tailscale-only)
│       └── prod.yml.example         # env=prod posture (CF-proxied public)
├── secrets.yml.example              # template for secrets.yml
├── infrastructure/
│   ├── ssl.conf.example             # cert domain list template
│   ├── grafana/                     # dashboards + datasources (static)
│   ├── loki/                        # loki-config.yml
│   ├── prometheus/                  # prometheus.yml
│   ├── promtail/                    # promtail-config.yml
│   └── tempo/                       # tempo-config.yml
├── playbooks/
│   ├── bootstrap.yml                # one-shot root bootstrap (new VM)
│   ├── site.yml                     # full provision (all roles)
│   └── deploy_app.yml               # single-app redeploy
├── roles/
│   ├── base/                        # OS hardening, Docker, ufw, swap
│   ├── tailscale/                   # install + auth + expose tailscale_ip
│   ├── ssl/                         # certbot DNS-01, per-domain cert lineages
│   ├── postgres/                    # init-databases.sh render
│   ├── observability/               # LGTM config sync
│   ├── nginx/                       # nginx config + infra docker-compose up
│   ├── fail2ban/                    # filters, jails, multi-domain CF ban
│   ├── origin_lockdown/             # ufw + DOCKER-USER chain (Prod)
│   └── apps/                        # per-app compose + vhost + DB
└── .github/dependabot.yml           # version bumps; no workflows shipped
```

---

## Playbook + role reference

| File | Purpose |
|---|---|
| `playbooks/bootstrap.yml` | Fresh-VM: create deploy user, harden SSH, disable root login. One-shot. |
| `playbooks/site.yml` | Full provision. Runs every role in order. Idempotent. |
| `playbooks/deploy_app.yml` | Single-app redeploy (image pull + compose up). |
| `roles/base` | Base packages, swap, Docker install, ufw baseline, GHCR login. |
| `roles/tailscale` | Install + authenticate via auth key. Prints DNS records you need. |
| `roles/ssl` | One cert lineage per domain via DNS-01. Self-signed placeholder for first run. |
| `roles/postgres` | Renders `init-databases.sh` (creates per-app DB + role on fresh volume). |
| `roles/observability` | Copies LGTM configs to `/opt/server/infrastructure/`. |
| `roles/nginx` | Renders nginx configs + infra `docker-compose.yml` + `.env`, runs `docker compose up -d`. |
| `roles/fail2ban` | Filters + jails + per-domain CF ban action. nginx jails Prod-only. |
| `roles/origin_lockdown` | Prod-only: restricts public :80/:443 to CF CIDRs (ufw + DOCKER-USER chain). |
| `roles/apps` | Per-app deploy: compose, vhost, scrape target, idempotent Postgres DB/role. |
