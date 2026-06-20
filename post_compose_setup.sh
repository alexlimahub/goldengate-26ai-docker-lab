#!/bin/bash
# =============================================================================
#  post_compose_setup.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Created: 2026-04-18
#  Full database post-compose setup: configure GoldenGate prerequisites,
#  install the HR sample schema, and enable Auto-CDR on all HR tables.
#
#  Run this script AFTER "docker compose up" and both database containers
#  are available.  It blocks until Oracle accepts connections before proceeding.
#
#  The DB image already has ARCHIVELOG mode and FORCE LOGGING enabled by
#  default, so no database restart is required.
#
#  Usage:  ./post_compose_setup.sh [OPTIONS]
#
#  Options:
#    --west             Configure WEST database only  (dbWEST, host port 1534)
#    --east             Configure EAST database only  (dbEAST, host port 1535)
#    --both             Configure both databases  (default)
#    --help, -h         Show this help and exit
#
#  Sequence per database:
#    1.  Wait for Oracle to accept SQL*Plus connections (up to 5 min)
#    2.  CDB  – streams_pool_size=512m (SCOPE=BOTH, no restart needed) /
#               enable_goldengate_replication / supplemental log data
#               (procedural + minimal)
#    3.  Mac  – download oracle-samples/db-sample-schemas (latest GitHub release)
#    4.  PDB (FREEPDB1) – create oggadmin user with all GoldenGate privileges
#                       – create hr user / install HR schema (create/populate/code)
#    5.  PDB (FREEPDB1) – add Auto-CDR (ACDR) to every table owned by HR
#    6.  Verification report
# =============================================================================

# ---------------------------------------------------------------------------
# Load .env from the same directory as this script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
else
    echo "ERROR: .env file not found in ${SCRIPT_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONTAINER_WEST="dbWEST"
CONTAINER_EAST="dbEAST"

ORACLE_PWD="${ORACLE_PASSWORD:?ERROR: ORACLE_PASSWORD not set. Copy .env.example to .env and set your password.}"

GITHUB_API="https://api.github.com/repos/oracle-samples/db-sample-schemas/releases/latest"
CONTAINER_SCHEMA_DIR="/tmp/hr_schema"   # staging path inside each container

DB_WAIT_TIMEOUT=300   # seconds to wait for Oracle to accept connections

# ---------------------------------------------------------------------------
# Terminal colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}================================================================${NC}"
}
print_step()  { echo -e "${CYAN}  >>> $1${NC}"; }
print_ok()    { echo -e "${GREEN}  [OK]    $1${NC}"; }
print_warn()  { echo -e "${YELLOW}  [WARN]  $1${NC}"; }
print_error() { echo -e "${RED}  [ERROR] $1${NC}"; }

# ---------------------------------------------------------------------------
# run_in_container <container> <bash_fragment>
#   Executes a bash script fragment inside the named container as oracle user.
# ---------------------------------------------------------------------------
run_in_container() {
    local container="$1"
    docker exec -u oracle -i "${container}" bash -s <<<"$2"
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    echo
    echo -e "${BOLD}Usage:${NC}  $0 [--west | --east | --both]"
    echo
    echo "  --west             Configure WEST database only  (${CONTAINER_WEST}, port 1534)"
    echo "  --east             Configure EAST database only  (${CONTAINER_EAST}, port 1535)"
    echo "  --both             Configure both databases  (default)"
    echo "  --help, -h         Show this help"
    echo
}

# ---------------------------------------------------------------------------
# wait_for_db <container> <label>
#   Polls every 5 s until FREEPDB1 reports READ WRITE in V$PDBS.
#
#   Why not just "sqlplus / as sysdba <<< exit"?
#   That only proves the CDB listener is up — the instance can accept a
#   sysdba OS-auth connection while still in MOUNT state or while the PDB
#   is still opening (RESTRICTED / MIGRATE).  We need FREEPDB1 to be fully
#   open before we try to create users or install schemas inside it.
# ---------------------------------------------------------------------------
wait_for_db() {
    local container="$1"
    local label="$2"
    local elapsed=0

    print_step "Waiting for FREEPDB1 to be READ WRITE in ${label} (timeout: ${DB_WAIT_TIMEOUT}s)..."

    while true; do
        # Query V$PDBS for FREEPDB1 open_mode.  Succeeds only when the PDB
        # is fully open; grep fails (returns non-zero) on any other state.
        if docker exec -u oracle "${container}" bash -c \
            '$ORACLE_HOME/bin/sqlplus -S / as sysdba <<< "
                SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
                SELECT open_mode FROM v\$pdbs WHERE name = '"'"'FREEPDB1'"'"';
                EXIT;" 2>/dev/null | grep -q "READ WRITE"'; then
            print_ok "${label} FREEPDB1 is READ WRITE and ready (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ ${elapsed} -ge ${DB_WAIT_TIMEOUT} ]]; then
            print_error "Timed out waiting for FREEPDB1 in ${container} after ${DB_WAIT_TIMEOUT}s"
            return 1
        fi
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            echo -e "${YELLOW}  ⏳ ${label} FREEPDB1 still opening... (${elapsed}s)${NC}"
        fi
    done
}

# ---------------------------------------------------------------------------
# configure_cdb <container> <label>
#   Single SQL*Plus session that applies CDB-level GoldenGate prerequisites.
#   ARCHIVELOG mode and FORCE LOGGING are already enabled in the base image,
#   so no database restart is required.  All parameters use SCOPE=BOTH so
#   they take effect immediately in memory and persist to the SPFILE.
# ---------------------------------------------------------------------------
configure_cdb() {
    local container="$1"
    local label="$2"

    print_step "Applying CDB-level GoldenGate configuration in ${label}..."
    echo

    # NOTE: <<'SQLEOF' is intentionally single-quoted so that neither the Mac
    # shell nor the container's bash expand Oracle identifiers like V$DATABASE.
    run_in_container "${container}" '
$ORACLE_HOME/bin/sqlplus / as sysdba <<'"'"'SQLEOF'"'"'
-- Continue past non-fatal errors (e.g. "parameter already set") so the
-- script is safely re-runnable.
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE

-- GoldenGate Integrated Extract memory pool
-- SCOPE=BOTH: takes effect immediately in memory and persists to SPFILE
--ALTER SYSTEM SET sga_max_size      = 1600m SCOPE=BOTH;
--ALTER SYSTEM SET sga_target        = 1600m SCOPE=BOTH;
--ALTER SYSTEM SET streams_pool_size = 512m  SCOPE=BOTH;

-- Activate GoldenGate integrated capture at the CDB level
ALTER SYSTEM SET ENABLE_GOLDENGATE_REPLICATION = TRUE SCOPE=BOTH;

-- Supplemental logging for PL/SQL and XStream procedural replication
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA FOR PROCEDURAL REPLICATION;

-- Minimal supplemental logging (required by all GoldenGate Extract processes)
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

EXIT;
SQLEOF
'
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        print_warn "SQL*Plus exited with code ${rc} — review output above for ORA- errors"
    else
        print_ok "CDB-level GoldenGate configuration applied in ${label}"
    fi
}

# ---------------------------------------------------------------------------
# download_schemas
#   Downloads the latest oracle-samples/db-sample-schemas ZIP from GitHub
#   into TMP_DIR (Mac-local, shared across containers).
#   Sets the global SCHEMA_ROOT variable to the extracted directory path.
#   Call once before processing any containers.
# ---------------------------------------------------------------------------
download_schemas() {
    TMP_DIR=$(mktemp -d)
    local zip_file="${TMP_DIR}/sample-schemas.zip"

    print_header "Downloading oracle-samples/db-sample-schemas (latest release)"

    print_step "Resolving latest release URL from GitHub API..."
    local location
    location=$(curl -s "${GITHUB_API}" \
        | grep "zipball_url" \
        | awk '{ print $2 }' \
        | sed 's/,$//' \
        | sed 's/"//g')

    if [[ -z "${location}" ]]; then
        print_error "Could not resolve download URL. Check internet / GitHub API rate limit."
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    print_ok "URL: ${location}"

    print_step "Downloading ZIP..."
    curl -L --progress-bar -o "${zip_file}" "${location}"
    if [[ $? -ne 0 ]]; then
        print_error "Download failed."
        rm -rf "${TMP_DIR}"
        exit 1
    fi

    print_step "Unzipping..."
    unzip -q "${zip_file}" -d "${TMP_DIR}"
    if [[ $? -ne 0 ]]; then
        print_error "Unzip failed."
        rm -rf "${TMP_DIR}"
        exit 1
    fi

    SCHEMA_ROOT=$(ls -d "${TMP_DIR}"/oracle-samples-db-sample-schemas-*/ 2>/dev/null | head -1)
    if [[ -z "${SCHEMA_ROOT}" ]]; then
        print_error "Could not locate extracted schema root in ${TMP_DIR}"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    print_ok "Schemas extracted: ${SCHEMA_ROOT}"
}

# ---------------------------------------------------------------------------
# install_pdb <container> <label>
#   Copies the HR schema files into the container, then runs a single
#   SQL*Plus session in FREEPDB1 that:
#     1. Creates the oggadmin user with all GoldenGate privileges
#     2. Creates the hr user with db_developer_role
#     3. Installs the HR sample schema (hr_create / hr_populate / hr_code)
#
#  Heredoc quoting strategy:
#    • Outer <<BASHEOF    – unquoted; Mac bash expands ${schema_dir} and
#                           ${pwd} into the script before sending to the container.
#    • Inner  <<'SQLEOF'  – single-quoted; the container's bash passes all SQL
#                           content verbatim to SQL*Plus (no shell expansion),
#                           which is correct since the password is already
#                           embedded as a literal by Mac bash above.
# ---------------------------------------------------------------------------
install_pdb() {
    local container="$1"
    local label="$2"
    local schema_dir="${CONTAINER_SCHEMA_DIR}"
    local pwd="${ORACLE_PWD}"

    # ── Copy HR schema files into the container ───────────────────────────
    local src_dir="${SCHEMA_ROOT}human_resources"
    if [[ ! -d "${src_dir}" ]]; then
        print_error "human_resources/ directory not found in ${SCHEMA_ROOT}"
        return 1
    fi

    print_step "Copying HR schema files into ${label} (${schema_dir})..."
    docker exec "${container}" bash -c "rm -rf '${schema_dir}'; mkdir -p '${schema_dir}'" 2>/dev/null
    docker cp "${src_dir}/." "${container}:${schema_dir}/"
    if [[ $? -ne 0 ]]; then
        print_error "docker cp failed for ${label}"
        return 1
    fi
    print_ok "HR schema files copied to ${schema_dir} in ${container}"

    # ── PDB setup + HR schema install (single SQL*Plus session) ──────────
    print_step "Creating users and installing HR schema in ${label} / FREEPDB1..."
    echo

    # cd to the schema dir first so that @hr_create.sql resolves relative
    # to that directory (same as @@ when run from command line).
    docker exec -u oracle -i "${container}" bash -s <<BASHEOF
cd '${schema_dir}'
\$ORACLE_HOME/bin/sqlplus / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET PAGESIZE 100
SET LINESIZE 140
SET FEEDBACK ON
SET ECHO     ON

-- ═══════════════════════════════════════════════════════════════════════════
-- Switch to the PDB
-- ═══════════════════════════════════════════════════════════════════════════
-- 21c / XE:  ALTER SESSION SET CONTAINER = xepdb1;
-- 23c / Free: FREEPDB1
ALTER SESSION SET CONTAINER = FREEPDB1;

-- ═══════════════════════════════════════════════════════════════════════════
-- GoldenGate admin user (ORA-01920 = user already exists → ignored)
-- No DEFAULT TABLESPACE clause — Oracle uses the PDB default (SYSAUX/SYSTEM).
-- GRANT UNLIMITED TABLESPACE avoids any quota/tablespace-name dependency.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE USER oggadmin
    IDENTIFIED BY "${pwd}"
    CONTAINER = CURRENT;

GRANT CREATE SESSION     TO oggadmin CONTAINER = CURRENT;
GRANT RESOURCE           TO oggadmin CONTAINER = CURRENT;
GRANT UNLIMITED TABLESPACE TO oggadmin;
GRANT OGG_CAPTURE        TO oggadmin;
GRANT OGG_APPLY          TO oggadmin;
GRANT SELECT ANY TABLE   TO oggadmin;
GRANT INSERT ANY TABLE   TO oggadmin;
GRANT UPDATE ANY TABLE   TO oggadmin;
GRANT DELETE ANY TABLE   TO oggadmin;

-- ═══════════════════════════════════════════════════════════════════════════
-- HR schema user
-- GRANT UNLIMITED TABLESPACE replaces QUOTA UNLIMITED ON USERS so no
-- specific tablespace name is required (Oracle 26ai Free PDB has no USERS).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE USER hr IDENTIFIED BY "${pwd}";
GRANT db_developer_role    TO hr;
GRANT UNLIMITED TABLESPACE TO hr;

-- ═══════════════════════════════════════════════════════════════════════════
-- Set session context and install the HR sample schema
-- ═══════════════════════════════════════════════════════════════════════════
ALTER SESSION SET CURRENT_SCHEMA = HR;
ALTER SESSION SET NLS_LANGUAGE   = American;
ALTER SESSION SET NLS_TERRITORY  = America;

@hr_create.sql
@hr_populate.sql
@hr_code.sql

EXIT;
SQLEOF
BASHEOF

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        print_ok "PDB setup and HR schema installed in ${label}"
    else
        print_warn "SQL*Plus session ended with code ${rc} — review output above for ORA- errors"
    fi
}

# ---------------------------------------------------------------------------
# configure_acdr <container> <label>
#   Connects as SYS / as sysdba, switches to FREEPDB1, and calls
#   DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR on every table in the HR schema.
#
#   NOTE: ACDR is invoked from within FREEPDB1 (not CDB$ROOT) so that
#   ALL_TABLES correctly returns the HR tables that live in the PDB.
#   additional_options:
#     0 → latest_timestamp_resolution  (last writer wins)
#     1 → earliest_timestamp_resolution
# ---------------------------------------------------------------------------
configure_acdr() {
    local container="$1"
    local label="$2"

    print_step "Enabling Auto-CDR (ACDR) on all HR tables in ${label} / FREEPDB1..."
    echo

    run_in_container "${container}" '
$ORACLE_HOME/bin/sqlplus / as sysdba <<'"'"'SQLEOF'"'"'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET PAGESIZE 100
SET LINESIZE 140

-- Switch to the PDB where HR tables live
ALTER SESSION SET CONTAINER = FREEPDB1;

BEGIN
    FOR t IN (SELECT owner, table_name
                FROM all_tables
               WHERE owner IN ('"'"'HR'"'"'))
    LOOP
        DBMS_OUTPUT.PUT_LINE('"'"'Adding ACDR: '"'"' || t.owner || '"'"'.'"'"' || t.table_name);
        DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
            schema_name        => t.owner,
            table_name         => t.table_name,
            record_conflicts   => TRUE,
            additional_options => 0
            -- additional_options: 0 = latest_timestamp_resolution
            --                     1 = earliest_timestamp_resolution
        );
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('"'"'ACDR enabled on all HR tables.'"'"');
END;
/

EXIT;
SQLEOF
'
    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        print_ok "ACDR configured for all HR tables in ${label}"
    else
        print_warn "SQL*Plus exited with code ${rc} — review output above for ORA- errors"
    fi
}

# ---------------------------------------------------------------------------
# verify_db <container> <label>
#   Prints a summary report: CDB parameters, log mode, supplemental logging,
#   FREEPDB1 user status, HR table count, and ACDR configuration.
# ---------------------------------------------------------------------------
verify_db() {
    local container="$1"
    local label="$2"

    print_step "Verification report for ${label}..."
    echo

    run_in_container "${container}" '
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'"'"'SQLEOF'"'"'
SET PAGESIZE  60
SET LINESIZE  140
SET FEEDBACK  OFF
SET ECHO      OFF
SET DEFINE    OFF

PROMPT ━━ CDB Parameters ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN name  FORMAT A45
COLUMN value FORMAT A30
SELECT NAME, VALUE
FROM   V$PARAMETER
WHERE  NAME IN (
           '"'"'enable_goldengate_replication'"'"',
           '"'"'streams_pool_size'"'"',
           '"'"'log_archive_format'"'"'
       )
ORDER BY NAME;

PROMPT ━━ CDB Log Mode and Supplemental Logging ━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN log_mode                  FORMAT A12  HEADING '"'"'LOG_MODE'"'"'
COLUMN force_logging             FORMAT A6   HEADING '"'"'FORCE'"'"'
COLUMN supplemental_log_data_min FORMAT A7   HEADING '"'"'SUP_MIN'"'"'
COLUMN supplemental_log_data_pk  FORMAT A6   HEADING '"'"'SUP_PK'"'"'
SELECT LOG_MODE, FORCE_LOGGING, SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_PK
FROM   V$DATABASE;

PROMPT ━━ FREEPDB1 — User Status ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ALTER SESSION SET CONTAINER = FREEPDB1;

COLUMN username           FORMAT A12
COLUMN account_status     FORMAT A18
COLUMN default_tablespace FORMAT A15
SELECT USERNAME, ACCOUNT_STATUS, DEFAULT_TABLESPACE
FROM   DBA_USERS
WHERE  USERNAME IN ('"'"'OGGADMIN'"'"', '"'"'HR'"'"')
ORDER BY USERNAME;

PROMPT ━━ FREEPDB1 — HR Table Count ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT COUNT(*) AS hr_table_count
FROM   DBA_TABLES
WHERE  OWNER = '"'"'HR'"'"';

PROMPT ━━ FREEPDB1 — ACDR Configuration (HR) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN owner        FORMAT A8
COLUMN object_name  FORMAT A30
COLUMN support_mode FORMAT A14  HEADING '"'"'SUPPORT_MODE'"'"'
SELECT OWNER, OBJECT_NAME, SUPPORT_MODE
FROM   DBA_GOLDENGATE_SUPPORT_MODE
WHERE  OWNER = '"'"'HR'"'"'
ORDER BY OBJECT_NAME;

EXIT;
SQLEOF
'
}

# ---------------------------------------------------------------------------
# setup_db <container> <label>
#   Orchestrates the full setup sequence for one database container.
# ---------------------------------------------------------------------------
setup_db() {
    local container="$1"
    local label="$2"

    print_header "Setting up ${label}  (container: ${container})"

    if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
        print_error "Container '${container}' is not running. Skipping."
        return 1
    fi
    print_ok "Container ${container} is running"

    wait_for_db       "${container}" "${label}" || return 1
    configure_cdb     "${container}" "${label}"
    install_pdb       "${container}" "${label}"
    configure_acdr    "${container}" "${label}"
    verify_db         "${container}" "${label}"

    echo
    print_ok "Full setup complete for ${label}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET="--both"

for arg in "$@"; do
    case "${arg}" in
        --west)   TARGET="--west" ;;
        --east)   TARGET="--east" ;;
        --both)   TARGET="--both" ;;
        --help|-h) usage; exit 0  ;;
        *)
            print_error "Unknown argument: ${arg}"
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}  Oracle GoldenGate — Post-Compose Database Setup${NC}"
echo -e "${BLUE}${BOLD}  $(date)${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"

# Download the sample schemas ZIP once — shared across both containers
download_schemas

# Configure the selected database(s)
case "${TARGET}" in
    --west) setup_db "${CONTAINER_WEST}" "WEST" ;;
    --east) setup_db "${CONTAINER_EAST}" "EAST" ;;
    --both)
        setup_db "${CONTAINER_WEST}" "WEST"
        setup_db "${CONTAINER_EAST}" "EAST"
        ;;
esac

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
print_step "Cleaning up temp files on Mac..."
rm -rf "${TMP_DIR}"
print_ok "Temp files removed"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Post-compose setup complete!${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo
echo "  What was configured per database:"
echo "    CDB : streams_pool_size = 512m  (SCOPE=BOTH, no restart)"
echo "          ENABLE_GOLDENGATE_REPLICATION = TRUE  (SCOPE=BOTH)"
echo "          Supplemental log data (procedural + minimal)"
echo "          (ARCHIVELOG + FORCE LOGGING already on in base image)"
echo "    PDB : FREEPDB1 — oggadmin user (GoldenGate capture + apply privileges)"
echo "          HR sample schema installed (create / populate / code)"
echo "          Auto-CDR (ACDR) enabled on all HR tables"
echo
echo "  Next steps:"
echo "    1.  Run  ./create_replication.sh  to configure GoldenGate processes"
echo "    2.  Verify WEST  →  https://localhost:9090  (oggadmin / ${ORACLE_PWD})"
echo "    3.  Verify EAST  →  https://localhost:8080  (oggadmin / ${ORACLE_PWD})"
echo "    4.  Connect to DB:"
echo "          WEST  →  localhost:1534/FREEPDB1"
echo "          EAST  →  localhost:1535/FREEPDB1"
echo
