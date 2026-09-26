# PPSV Project Management System

This repository contains the Shiny request-management system for the Protein
Production and Structural Validation Facility (PPSV) at the Max Planck
Institute of Biochemistry.

Production URL: `https://ppcf-vm.biochem.mpg.de/ppsv-app/`

Facility contact: [ppsv-request@biochem.mpg.de](mailto:ppsv-request@biochem.mpg.de),
+49 89 8578-3629.

## What the system does

PPSV provides one authenticated workflow for eight service modules and general
inquiries. It includes:

- workbook-derived submission forms and validation;
- LDAP-prefilled requester profiles and allowlist-derived roles;
- request ownership, staff assignment, seven-state status history, and soft
  archive;
- input and result files stored outside the web root with SHA-256 checksums;
- PPSV PDF summaries without prices, costs, or invoice data;
- a durable ticket-mail outbox with recorded delivery attempts; and
- an admin user directory for activation, deactivation, and last-login review.

The application deliberately has no sample tables, cost estimates, invoices,
price lists, data-release workflow, or permanent-purge operation.

## Security and data boundaries

Apache is the only public entry point. It authenticates against LDAP, removes
client-supplied identity headers, injects the authenticated identity, and
proxies HTTP and WebSocket traffic to Shiny Server on loopback. Production must
use `AUTH_MODE=ldap`; test-mode identities are only for automated tests and
local development.

Mutable state is outside immutable releases:

| Purpose | Production path |
|---|---|
| Active application symlink | `/srv/shiny-server/ppsv-app` |
| Immutable releases | `/srv/ppsv-app/releases` |
| SQLite database and fallback storage | `/srv/ppsv-app-data` |
| Primary request files | `/fs/pool/pool-ppsvf-projects` |
| Runtime secrets | `/etc/ppsv-app/ppsv-app.env` |

Never deploy or migrate the copied `ms_projects.db`. PPSV initializes a fresh
database at `PPSV_DB_FILE` and subsequently applies only PPSV migrations. Do
not place a database, upload directory, real secret, or `.Renviron` in
`ppsv-app/`.

## Repository layout

| Path | Contents |
|---|---|
| `ppsv-app/` | Shiny application, backend modules, migrations, assets, and `renv.lock` |
| `scripts/` | Idempotent provisioning, deployment, rollback, backup, restore, mail, and storage operations |
| `tests/testthat/` | Schema, authorization, mail, storage, PDF, and UI tests |
| `PPSV_Submission_form.xlsx` | Source reference for the 18 required and eight optional service fields |
| `chapters/` | Quarto operator and developer documentation |

## Local development

Restore the locked dependencies and run with an isolated database and upload
directory. Never point local development at production paths.

```bash
(cd ppsv-app && Rscript -e 'renv::restore(project = getwd(), prompt = FALSE)')
dev_root="$(mktemp -d)"
mkdir -p "${dev_root}/pool" "${dev_root}/fallback"
AUTH_MODE=test \
PPSV_TEST_USER=developer \
PPSV_TEST_NAME='Local Developer' \
PPSV_TEST_EMAIL='developer@example.org' \
PPSV_DB_FILE="${dev_root}/ppsv.sqlite" \
PPSV_POOL_ROOT="${dev_root}/pool" \
PPSV_ALLOW_LOCAL_POOL=1 \
PPSV_FALLBACK_ROOT="${dev_root}/fallback" \
Rscript -e 'shiny::runApp("ppsv-app", port = 3838, launch.browser = TRUE)'
```

Run the automated checks from the repository root:

```bash
Rscript tests/testthat.R
bash -n scripts/*.sh deploy.sh
```

The production preflight additionally checks the pinned operating system,
architecture, Shiny Server version, Java configuration, and `rJava`/`mailR`
runtime.

## Production workflow

Production installation is an administrator handoff, not an action performed
by the application repository itself.

1. Resolve the four external readiness gates: the exact matching TLS private
   key, authorization for `ppsv-service@biochem.mpg.de`, a real ticket
   requester/auto-reply test, and an external backup destination plus facility
   pool-snapshot policy.
2. Create a root-owned environment file from
   `scripts/ppsv-app.env.example`; mode must be `0640` or stricter.
3. Install a reviewed Shiny Server package with
   `scripts/install_shiny_server.sh --env /root/ppsv-app.env --deb ...`; the
   template pins the independently reviewed SHA-256 checksum.
4. Run `sudo scripts/provision.sh --env /path/to/operator.env`.
5. Run `sudo scripts/deploy.sh --source "$PWD"`.
6. After the external-gate acknowledgement values are supported by evidence,
   run `sudo scripts/verify_deployment.sh` with a test netrc and ordinary LDAP
   username as documented in the operator guide, followed by the manual
   acceptance tests.

Deployments stage a release, restore locked R packages, make a verified
pre-deployment backup, apply database migrations transactionally, switch the
application symlink atomically, and health-check the result. Code rollback is
separate from database restore because restoring a database can discard newer
requests.

## Documentation

Render or preview the Quarto book from the repository root:

```bash
quarto preview
```

Start with [Operator quick start](chapters/quick-start.qmd). The
[acceptance and handoff checklist](chapters/acceptance.qmd) is the authoritative
production-readiness record.
