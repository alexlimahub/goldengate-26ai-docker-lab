#!/bin/bash
# =============================================================================
#  3_archivelog_cleanup.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Created: 2026-04-18
#  Mac-side management script.  Deploys a container-native archivelog cleanup
#  script into dbWEST and dbEAST, then installs a cron job (every 5 minutes)
#  so the cleanup runs autonomously inside each Oracle container.
#
#  Usage:  ./3_archivelog_cleanup.sh [--setup | --status | --logs | --run-now | --remove]
#
#    --setup    (default) Copy script into containers and install cron entry
#    --status   Show cron status, live disk usage, and recent log lines
#    --logs     Tail the cleanup log from both containers (Ctrl-C to stop)
#    --run-now  Trigger a one-shot check inside both containers right now
#    --remove   Remove cron entry and script from both containers
#
#  What the container-side script does (every 5 minutes, as oracle user):
#    1. df /opt/oracle — read current filesystem usage %
#    2. If usage >= THRESHOLD (80%):
#         a. SQL  → find the MIN(sequence#) in the newest KEEP_LAST (5) archivelogs
#         b. RMAN → CROSSCHECK + DELETE NOPROMPT ARCHIVELOG UNTIL SEQUENCE <n>
#    3. Log before/after usage to /home/oracle/archivelog_cleanup.log
#       (auto-rotates at 1 000 lines to avoid unbounded growth)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

CONTAINER_WEST="${CONTAINER_WEST:-dbWEST}"
CONTAINER_EAST="${CONTAINER_EAST:-dbEAST}"
INNER_SCRIPT="/home/oracle/archivelog_cleanup.sh"
INNER_LOG="/home/oracle/archivelog_cleanup.log"

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
    echo -e "${BLUE}${BOLD}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}════════════════════════════════════════════════${NC}"
}
print_step()  { echo -e "${CYAN}  >>> $1${NC}"; }
print_ok()    { echo -e "${GREEN}  [OK]    $1${NC}"; }
print_warn()  { echo -e "${YELLOW}  [WARN]  $1${NC}"; }
print_error() { echo -e "${RED}  [ERROR] $1${NC}"; }

# ---------------------------------------------------------------------------
# deploy_to_container <container> <label>
#   Writes the cleanup script, ensures crond is running, installs crontab.
# ---------------------------------------------------------------------------
deploy_to_container() {
    local container="$1"
    local label="$2"

    if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
        print_error "${label}: container '${container}' is not running — skipping"
        return 1
    fi

    # ── 1. Write the container-native cleanup script ─────────────────────────
    print_step "${label}: writing ${INNER_SCRIPT} ..."

    # NOTE: <<'DEPLOY_EOF' is single-quoted on the Mac side, so NO Mac variable
    # expansion occurs.  Everything inside is sent verbatim into the container
    # and written to the file by the 'tee' command running there.
    docker exec -u oracle -i "${container}" bash -s <<'DEPLOY_EOF'
tee /home/oracle/archivelog_cleanup.sh > /dev/null << 'INNER_EOF'
#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  archivelog_cleanup.sh  (runs INSIDE the container as the oracle user)
#  Deployed by 3_archivelog_cleanup.sh — do not edit manually.
# ─────────────────────────────────────────────────────────────────────────────

# Source Oracle environment — cron does not source .bash_profile by default
[[ -f /etc/profile    ]] && . /etc/profile
[[ -f ~/.bash_profile ]] && . ~/.bash_profile

# Fallback: locate Oracle home if $ORACLE_HOME is still not set
if [[ -z "$ORACLE_HOME" ]]; then
    ORACLE_HOME=$(find /opt/oracle/product -name "sqlplus" -type f 2>/dev/null \
                  | head -1 | sed 's|/bin/sqlplus||')
fi
export ORACLE_HOME
export PATH="${ORACLE_HOME}/bin:${PATH}"
ORACLE_SID="${ORACLE_SID:-FREE}"
export ORACLE_SID

# ── Configuration ────────────────────────────────────────────────────────────
THRESHOLD=80           # % full that triggers cleanup
KEEP_LAST=5            # number of archivelogs to preserve (newest first)
ORACLE_DATA_PATH="/opt/oracle"
LOG_FILE="/home/oracle/archivelog_cleanup.log"
MAX_LOG_LINES=1000     # rotate when log exceeds this many lines

# ── Helpers ──────────────────────────────────────────────────────────────────
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [$1] $2" | tee -a "${LOG_FILE}"; }

# ── Log rotation ─────────────────────────────────────────────────────────────
if [[ -f "${LOG_FILE}" ]]; then
    line_count=$(wc -l < "${LOG_FILE}" 2>/dev/null)
    if (( line_count > MAX_LOG_LINES )); then
        tail -500 "${LOG_FILE}" > "${LOG_FILE}.tmp" \
            && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        log INFO "Log rotated (was ${line_count} lines)"
    fi
fi

# ── Filesystem check ─────────────────────────────────────────────────────────
usage=$(df "${ORACLE_DATA_PATH}" 2>/dev/null \
        | awk 'NR==2 { gsub(/%/,""); print $5 }')

if [[ -z "$usage" || ! "$usage" =~ ^[0-9]+$ ]]; then
    log WARN "Cannot read usage from ${ORACLE_DATA_PATH} — aborting"
    exit 1
fi

log INFO "${ORACLE_DATA_PATH} = ${usage}% used  (threshold ${THRESHOLD}%)"

(( usage < THRESHOLD )) && exit 0    # nothing to do

log WARN "${usage}% >= ${THRESHOLD}% — archivelog purge starting (keeping last ${KEEP_LAST})"

# ── Find minimum sequence# to keep ──────────────────────────────────────────
#   Query v$archived_log at CDB level (archivelogs are CDB-wide).
#   Using $ORACLE_HOME/bin/sqlplus directly — no docker exec needed.
raw=$("${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMOUT ON TRIMSPOO ON
SELECT NVL(MIN(sequence#), 0)
FROM (
    SELECT sequence#
    FROM   v\$archived_log
    WHERE  dest_id      = 1
      AND  standby_dest = 'NO'
      AND  deleted      = 'NO'
    ORDER  BY sequence# DESC
    FETCH  FIRST ${KEEP_LAST} ROWS ONLY
);
EXIT;
SQL
)

min_seq=$(echo "$raw" \
          | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' \
          | tail -1 \
          | tr -d '[:space:]')

if [[ -z "$min_seq" || "$min_seq" -eq 0 ]]; then
    log WARN "Could not determine sequence cutoff (got: '${raw}') — aborting"
    exit 1
fi

log INFO "Deleting archivelogs with sequence# < ${min_seq} via RMAN"

# ── RMAN delete ──────────────────────────────────────────────────────────────
"${ORACLE_HOME}/bin/rman" target / nocatalog >> "${LOG_FILE}" 2>&1 <<RMAN
CROSSCHECK ARCHIVELOG ALL;
DELETE NOPROMPT ARCHIVELOG UNTIL SEQUENCE ${min_seq} THREAD 1;
EXIT;
RMAN

# ── Report new usage ─────────────────────────────────────────────────────────
new_usage=$(df "${ORACLE_DATA_PATH}" 2>/dev/null \
            | awk 'NR==2 { gsub(/%/,""); print $5 }')
log OK "Cleanup done — ${ORACLE_DATA_PATH} now ${new_usage}%  (was ${usage}%)"
INNER_EOF

chmod 750 /home/oracle/archivelog_cleanup.sh
echo "Script written OK"
DEPLOY_EOF

    # ── 2. Make sure crond is installed and running (as root) ────────────────
    print_step "${label}: ensuring crond is installed and running ..."

    docker exec -u 0 "${container}" bash -s <<'ROOT_EOF'
# Install cronie if crontab binary is missing
if ! command -v crontab &>/dev/null; then
    echo "  Installing cronie..."
    yum install -y cronie 2>&1 | tail -3 \
        || dnf install -y cronie 2>&1 | tail -3
fi

# Start crond if not already running
if ! pgrep -x crond &>/dev/null; then
    echo "  Starting crond..."
    crond
    sleep 1
    pgrep -x crond &>/dev/null && echo "  crond started OK" \
                                || echo "  WARNING: crond may not have started"
else
    echo "  crond already running"
fi
ROOT_EOF

    # ── 3. Install crontab entry for oracle user (idempotent) ────────────────
    print_step "${label}: installing crontab entry (every 5 minutes) ..."

    docker exec -u oracle "${container}" bash -s <<'CRON_EOF'
# Remove any existing entry for this script, then append a fresh one
(
    crontab -l 2>/dev/null | grep -v 'archivelog_cleanup'
    echo "*/5 * * * * /home/oracle/archivelog_cleanup.sh"
) | crontab -
echo "Crontab after update:"
crontab -l
CRON_EOF

    print_ok "${label}: deployed and scheduled ✓"
}

# ---------------------------------------------------------------------------
# setup — deploy to both containers
# ---------------------------------------------------------------------------
setup() {
    print_header "Archivelog Cleanup — Deploy to Containers"
    deploy_to_container "${CONTAINER_WEST}" "WEST"
    echo
    deploy_to_container "${CONTAINER_EAST}" "EAST"
    echo
    print_ok "Done.  Cleanup runs every 5 minutes inside both containers."
    echo
    echo "  Manage:"
    echo "    Status : $0 --status"
    echo "    Logs   : $0 --logs"
    echo "    Remove : $0 --remove"
}

# ---------------------------------------------------------------------------
# status — disk usage + cron status + recent log from both containers
# ---------------------------------------------------------------------------
status() {
    print_header "Archivelog Cleanup — Status"

    for pair in "WEST:${CONTAINER_WEST}" "EAST:${CONTAINER_EAST}"; do
        local lbl="${pair%%:*}"
        local ctr="${pair##*:}"

        echo -e "\n${BOLD}  ── ${lbl} (${ctr}) ──────────────────────────────────────${NC}"

        if ! docker ps --format '{{.Names}}' | grep -qx "${ctr}"; then
            print_error "  Container not running"
            continue
        fi

        docker exec -u oracle "${ctr}" bash -s <<'STATUS_EOF'
# Disk usage
usage=$(df /opt/oracle 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
echo "  Filesystem /opt/oracle : ${usage}% used"

# Script present?
if [[ -x /home/oracle/archivelog_cleanup.sh ]]; then
    echo "  Script    : /home/oracle/archivelog_cleanup.sh  [installed]"
else
    echo "  Script    : NOT installed"
fi

# cron entry?
entry=$(crontab -l 2>/dev/null | grep 'archivelog_cleanup' || true)
if [[ -n "$entry" ]]; then
    echo "  Cron entry: ${entry}"
else
    echo "  Cron entry: NOT found"
fi

# crond running?
if pgrep -x crond &>/dev/null; then
    echo "  crond     : running"
else
    echo "  crond     : NOT running"
fi

# Last 10 log lines
echo
echo "  Last 10 log lines:"
tail -10 /home/oracle/archivelog_cleanup.log 2>/dev/null | sed 's/^/    /' \
    || echo "    (log not yet created)"
STATUS_EOF
    done
    echo
}

# ---------------------------------------------------------------------------
# logs — tail live logs from both containers (Ctrl-C to stop)
# ---------------------------------------------------------------------------
show_logs() {
    echo -e "\n${CYAN}Tailing archivelog cleanup logs — Ctrl-C to stop${NC}\n"

    for pair in "WEST:${CONTAINER_WEST}" "EAST:${CONTAINER_EAST}"; do
        local lbl="${pair%%:*}"
        local ctr="${pair##*:}"
        if docker ps --format '{{.Names}}' | grep -qx "${ctr}"; then
            echo -e "${BOLD}=== ${lbl} ===${NC}"
            docker exec "${ctr}" tail -30 "${INNER_LOG}" 2>/dev/null \
                || echo "  (log not yet created)"
            echo
        fi
    done

    echo -e "${YELLOW}Streaming new entries (both containers merged):${NC}"
    # Stream both logs together; label each line with the container name
    for pair in "WEST:${CONTAINER_WEST}" "EAST:${CONTAINER_EAST}"; do
        local lbl="${pair%%:*}"
        local ctr="${pair##*:}"
        if docker ps --format '{{.Names}}' | grep -qx "${ctr}"; then
            docker exec "${ctr}" tail -f "${INNER_LOG}" 2>/dev/null \
                | sed "s/^/[${lbl}] /" &
        fi
    done
    wait
}

# ---------------------------------------------------------------------------
# run_now — trigger a one-shot run inside both containers immediately
# ---------------------------------------------------------------------------
run_now() {
    print_header "Archivelog Cleanup — Manual Trigger"

    for pair in "WEST:${CONTAINER_WEST}" "EAST:${CONTAINER_EAST}"; do
        local lbl="${pair%%:*}"
        local ctr="${pair##*:}"

        echo -e "\n${BOLD}  ── ${lbl} (${ctr}) ──────────────────────────────────────${NC}"

        if ! docker ps --format '{{.Names}}' | grep -qx "${ctr}"; then
            print_error "  Container not running"
            continue
        fi

        if ! docker exec -u oracle "${ctr}" test -x "${INNER_SCRIPT}" 2>/dev/null; then
            print_warn "  Script not installed — run '$0 --setup' first"
            continue
        fi

        print_step "${lbl}: running cleanup now..."
        docker exec -u oracle "${ctr}" bash "${INNER_SCRIPT}"
        print_ok "${lbl}: done"
    done
    echo
}

# ---------------------------------------------------------------------------
# remove — uninstall cron entry and script from both containers
# ---------------------------------------------------------------------------
remove() {
    print_header "Archivelog Cleanup — Remove from Containers"

    for pair in "WEST:${CONTAINER_WEST}" "EAST:${CONTAINER_EAST}"; do
        local lbl="${pair%%:*}"
        local ctr="${pair##*:}"

        echo -e "\n${BOLD}  ── ${lbl} (${ctr}) ──────────────────────────────────────${NC}"

        if ! docker ps --format '{{.Names}}' | grep -qx "${ctr}"; then
            print_warn "  Container not running — skipping"
            continue
        fi

        docker exec -u oracle "${ctr}" bash -s <<'REMOVE_EOF'
# Remove crontab entry
crontab -l 2>/dev/null | grep -v 'archivelog_cleanup' | crontab -
echo "  Cron entry removed"

# Remove script
rm -f /home/oracle/archivelog_cleanup.sh
echo "  Script removed"
REMOVE_EOF

        print_ok "${lbl}: uninstalled"
    done
    echo
    print_ok "Archivelog cleanup removed from all containers."
}

# ---------------------------------------------------------------------------
# Argument dispatch
# ---------------------------------------------------------------------------
MODE="${1:---setup}"

case "$MODE" in
    --setup)    setup    ;;
    --status)   status   ;;
    --logs)     show_logs ;;
    --run-now)  run_now  ;;
    --remove)   remove   ;;
    --help | -h)
        echo
        echo -e "${BOLD}Usage:${NC}  $0 [--setup | --status | --logs | --run-now | --remove]"
        echo
        echo "  --setup     Copy script into containers and install cron (default)"
        echo "  --status    Show disk usage, cron status, and recent log entries"
        echo "  --logs      Tail the cleanup log from both containers"
        echo "  --run-now   Manually trigger a cleanup check right now"
        echo "  --remove    Uninstall cron entry and script from both containers"
        echo
        echo "  Container-side config (edit INNER_SCRIPT to change):"
        echo "    THRESHOLD=80       % full that triggers archivelog purge"
        echo "    KEEP_LAST=5        newest archivelogs to preserve"
        echo "    Cron schedule: */5 * * * *  (every 5 minutes)"
        echo
        ;;
    *)
        echo "Unknown option: $MODE"
        echo "Run '$0 --help' for usage."
        exit 1
        ;;
esac
