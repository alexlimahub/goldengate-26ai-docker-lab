# Oracle GoldenGate 23ai Lab — Docker Compose

A fully automated Docker Compose lab that provisions two Oracle Database 26ai Free instances with unidirectional GoldenGate replication (WEST → EAST) and Veridata data comparison — all running locally on a single machine.

---

## Architecture

```
  ┌────────────────────────────────────────────────────────┐
  │                  Docker Network (172.52.0.0/16)        │
  │                                                        │
  │   ┌──────────────┐              ┌──────────────┐      │
  │   │  dbWEST      │              │  dbEAST      │      │
  │   │  Oracle 26ai │              │  Oracle 26ai │      │
  │   │  port 1534   │              │  port 1535   │      │
  │   └──────┬───────┘              └──────▲───────┘      │
  │          │                             │              │
  │   ┌──────▼───────┐              ┌──────┴───────┐      │
  │   │  oggWEST     │──DP──Trail──►│  oggEAST     │      │
  │   │  GoldenGate  │              │  GoldenGate  │      │
  │   │  port 9090   │              │  port 8080   │      │
  │   └──────────────┘              └──────────────┘      │
  │                                                        │
  │   ┌──────────────────────────────────────────────┐     │
  │   │  Veridata 23.26  (port 8831)                 │     │
  │   │  Compares HR schema between WEST and EAST    │     │
  │   └──────────────────────────────────────────────┘     │
  └────────────────────────────────────────────────────────┘
```

**Replication pipeline (unidirectional WEST → EAST):**
- `EWEST` → trail `ew` → `DPWE` → trail `dw` → `RWEST` → dbEAST
- HR schema is installed on both databases with Auto-CDR (conflict detection) enabled

---

## Platform Notes

This lab was developed and tested on **macOS Apple Silicon (ARM64)**. The `platform` settings in `compose.yaml` may need to be adjusted depending on your host:

| Service | Current image/platform | Mac ARM (M1/M2/M3) | Mac Intel / Linux x86 / Windows (WSL2) |
|---------|----------------------|-------------------|----------------------------------------|
| GoldenGate (ggw/gge) | `linux/amd64` | Runs via Rosetta emulation — no change needed | Native — no change needed |
| Veridata | `linux/amd64` | Runs via Rosetta emulation — no change needed | Native — no change needed |
| Oracle DB (databaseW/databaseE) | `linux/arm64` + `-arm64` image tag | Native — no change needed | **Change required** — see below |

### Oracle DB image on Intel / Linux x86 / Windows

The DB image tag in `compose.yaml` is the ARM64 build (`23.26.1.0-lite-arm64`). On non-ARM hosts, replace it with the x86_64 equivalent for both `databaseW` and `databaseE`:

```yaml
# Replace this (ARM64 — Mac Apple Silicon):
image: container-registry.oracle.com/database/free:23.26.1.0-lite-arm64
platform: "linux/arm64"

# With this (x86_64 — Intel Mac / Linux / Windows WSL2):
image: container-registry.oracle.com/database/free:latest
platform: "linux/amd64"
```

> On **Windows**, run everything inside WSL2 with Docker Desktop's WSL2 backend enabled. The `linux/amd64` platform applies.

> On **Linux ARM64** (e.g. AWS Graviton), the DB image can stay as-is, but GoldenGate and Veridata will run under emulation (`linux/amd64`) — performance may vary.

---

## Prerequisites

- Docker Desktop (with at least 16 GB RAM allocated)
- `docker compose` v2+
- `curl`, `unzip` available on the host machine
- An Oracle account — **see license notice below**

---

## ⚠️ Oracle Container Registry — License Acceptance Required

All images used by this lab are hosted on the **Oracle Container Registry (OCR)** at `container-registry.oracle.com`.

| Image | Registry path |
|-------|--------------|
| Oracle GoldenGate 23ai | `container-registry.oracle.com/goldengate/goldengate-oracle:latest` |
| Oracle Database 23ai Free | `container-registry.oracle.com/database/free:23.26.1.0-lite-arm64` |
| Oracle GoldenGate Veridata | `container-registry.oracle.com/goldengate/goldengate-veridata:23.26.1.0.1` |

**Before pulling any image or running `docker compose up`, you must accept the license for each image:**

1. Go to [https://container-registry.oracle.com](https://container-registry.oracle.com)
2. Sign in with your Oracle account (free registration)
3. Search for each repository listed above and click **Accept License**
4. Log in to OCR from your terminal:
   ```bash
   docker login container-registry.oracle.com
   ```

You can then pull the images manually to verify access before running the lab:

```bash
docker pull container-registry.oracle.com/goldengate/goldengate-oracle:latest
docker pull container-registry.oracle.com/database/free:23.26.1.0-lite-arm64
docker pull container-registry.oracle.com/goldengate/goldengate-veridata:23.26.1.0.1
```

> **Note:** Pulling without accepting the license will result in a `401 Unauthorized` or `403 Forbidden` error even after `docker login`.

---

## Quick Start

### 1. Clone and configure

```bash
git clone <this-repo-url>
cd <repo-dir>

cp .env.example .env
cp vdt.env.example vdt.env
```

**Open both files and set your passwords** — replace every `<your-password>` placeholder before running the lab:

| File | Variables to set |
|------|-----------------|
| `.env` | `OGG_ADMIN_PWD`, `ORACLE_PASSWORD`, `GF_SECURITY_ADMIN_PASSWORD` |
| `vdt.env` | `VDT_ADMINISTRATOR_PASSWORD` |

> All services share the same password by convention. Choose one that meets Oracle's policy: at least 8 characters with upper, lower, digit, and special character (e.g. `MyLab##2026`).

### 2. Accept OCR licenses and log in (see above)

```bash
docker login container-registry.oracle.com
```

### 3. Run the lab

```bash
./0_start_lab.sh
```

This single script orchestrates the full setup (~15–25 min depending on hardware):

| Step | Script | What happens |
|------|--------|-------------|
| 1 | — | `docker compose down -v` — clean slate |
| 2 | — | `docker compose up -d` — start all containers |
| 3 | `post_compose_setup.sh` | Configure DBs, install HR schema, enable ACDR |
| 4 | `3_archivelog_cleanup.sh --setup` | Deploy archivelog purge cron inside containers |
| 5 | `1_create_replication.sh` | Create GoldenGate extract, distribution path, replicat |
| 6–8 | `Veridata/0_check_veridata_agents.sh` | Agent status check before and after setup |
| 7 | `Veridata/1_create_veridata_agent.sh` | Create Veridata agent deployment |
| 9 | `Veridata/2_create_veridata_connections.sh` | Create WEST + EAST database connections |
| 10 | `Veridata/3_create_veridata_profile.sh` | Create all comparison profiles |
| 11 | `Veridata/4_create_veridata_group_and_pairs.sh` | Create HR compare group and table pairs |
| 12 | `Veridata/5_run_veridata_comparison.sh` | Run initial HR comparison |
| 13 | `Veridata/6_schedule_veridata_job.sh` | Schedule daily comparison job |

---

## Access URLs

| Service | URL | Default user |
|---------|-----|-------------|
| GoldenGate WEST | https://localhost:9090 | `oggadmin` |
| GoldenGate EAST | https://localhost:8080 | `oggadmin` |
| Veridata | https://localhost:8831/veridata | `veridata` |
| Database WEST | `localhost:1534/FREEPDB1` | `sys` |
| Database EAST | `localhost:1535/FREEPDB1` | `sys` |

Passwords are set in `.env` and `vdt.env`. The GoldenGate UI uses a self-signed certificate — accept the browser warning on first access.

---

## Repository Structure

```
.
├── 0_start_lab.sh                  # Main entry point — runs all steps in order
├── 0_wait_for_stack.sh             # Polls GG + DB endpoints until the stack is ready
├── post_compose_setup.sh           # DB config: GG params, HR schema, Auto-CDR
├── 1_create_replication.sh         # GoldenGate process creation
├── 2_generate_load.sh              # Generates DML load on WEST for replication testing
├── 3_archivelog_cleanup.sh         # Archivelog purge cron (runs inside containers)
├── 4_delete_lab.sh                 # Tears down the stack and removes all volumes
├── initial_load.sh                 # Full initial load: instantiates EAST from WEST while replication stays active
├── add_acdr_schema.sql             # Reference: how to enable Auto-CDR on a custom schema
├── compose.yaml                    # Docker Compose stack definition
├── .env.example                    # Environment variable template → copy to .env
├── vdt.env.example                 # Veridata environment template → copy to vdt.env
├── vdt-entrypoint.sh               # Custom entrypoint mounted into the Veridata container
├── cert/
│   ├── ca.pem                      # CA certificate for GG TLS
│   ├── ogg.pem                     # GG server certificate
│   └── ogg.key                     # GG server private key (excluded from git)
├── Grafana/
│   └── Main Dashboard-*.json       # Grafana dashboard exports (optional import)
└── Veridata/
    ├── 0_check_veridata_agents.sh
    ├── 1_create_veridata_agent.sh
    ├── 2_create_veridata_connections.sh
    ├── 3_create_veridata_profile.sh
    ├── 4_create_veridata_group_and_pairs.sh
    ├── 5_run_veridata_comparison.sh
    └── 6_schedule_veridata_job.sh
```

---

## Initial Load — Synchronizing WEST → EAST

After replication is running, the data on both databases may be out of sync (EAST started empty or diverged). To perform a full initial load that instantiates all HR tables from WEST into EAST while keeping change replication active, run:

```bash
./initial_load.sh
```

This script automates the full GoldenGate initial load workflow:

1. Stops and deletes existing replication processes (RWEST, DPWE, EWEST)
2. Creates a new online change extract (`EWEST`) to capture changes during the load
3. Captures the current SCN (System Change Number) from WEST
4. Creates an initial load extract (`EINIT`) using `source:tables` — reads directly from WEST without impacting the change pipeline
5. Streams data via a distribution path (`DPEI`) to EAST in parallel as EINIT writes
6. Creates and runs an initial load replicat (`RINIT`) on EAST to apply all rows
7. Once RINIT finishes, re-enables foreign key constraints on EAST
8. Starts the change replicat (`RWEST`) at the captured SCN so no changes are missed

> **When to use:** Run `initial_load.sh` any time EAST is empty, has been reset, or you suspect data drift between the two databases.

---

## Bonus — Auto-CDR Schema Reference

The file `add_acdr_schema.sql` shows how **Auto-CDR (Automatic Conflict Detection and Resolution)** is enabled at the schema level in Oracle 26ai. It is pre-applied to the HR schema by `post_compose_setup.sh`, but is included here as a reference for customers who want to enable it on their own schemas:

```bash
# View the script
cat add_acdr_schema.sql
```

Auto-CDR uses a last-writer-wins strategy based on commit timestamps and requires no application changes — Oracle handles conflict resolution automatically during GoldenGate apply.

---

## Common Operations

**Re-run Veridata comparison:**
```bash
./Veridata/5_run_veridata_comparison.sh --profile HR_PROFILE_MEDIUM --latest-group
```

**Check archivelog cleanup status:**
```bash
./3_archivelog_cleanup.sh --status
./3_archivelog_cleanup.sh --logs
```

**Delete the lab (full reset):**
```bash
./4_delete_lab.sh
```

**Stop containers but keep volumes (faster restart):**
```bash
./4_delete_lab.sh --soft
```

**Connect to a database container:**
```bash
docker exec -it dbWEST bash
docker exec -it dbEAST bash
```

---

## Notes

- The Oracle Database 23ai Free image has `ARCHIVELOG` mode and `FORCE LOGGING` enabled by default — no database restart is needed during setup.
- The HR schema is downloaded at runtime from the public [oracle-samples/db-sample-schemas](https://github.com/oracle-samples/db-sample-schemas) GitHub repository. Internet access is required during `post_compose_setup.sh`.
- GoldenGate processes use self-signed TLS certificates located in `cert/`. These are pre-generated for the lab and mounted into the GG containers.
- Veridata state is stored in a Docker named volume (`veridata_data`). Running `docker compose down -v` will reset it.

---

## Author

Alex Lima — Oracle GoldenGate Product Manager
