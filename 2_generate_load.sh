#!/bin/bash
# =============================================================================
#  2_generate_load.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Created: 2026-04-18
#  Creates a DBMS_SCHEDULER job inside Oracle that fires every 5 seconds and
#  runs DML against the HR schema, producing a continuous GoldenGate capture
#  stream with no manual intervention required.
#
#  Usage:  ./2_generate_load.sh [--west | --east | --both] [MODE]
#
#  Target (default: --west — source side, replication propagates to EAST):
#    --west     Run against WEST database only
#    --east     Run against EAST database only
#    --both     Run against both databases
#
#  Mode (default: --create):
#    --create   Drop and recreate the scheduler job  (idempotent, safe to re-run)
#    --stop     Disable the job (pauses DML; job definition is kept)
#    --start    Enable the job (resumes DML without recreating it)
#    --drop     Disable and drop the job entirely
#    --status   Show job stats — last run, run count, failures
#    --help, -h Show this help
#
#  What the job does every 5 seconds  (job name: HR_LOAD_JOB in FREEPDB1):
#    1. UPDATE  salary +/-50 for 5 employees (alternating by employee_id parity)
#    2. UPDATE  phone_number with current timestamp for 3 employees
#    3. INSERT  one test employee (first_name = 'GGLoad') — every run
#    4. DELETE  the single oldest GGLoad row when pool exceeds 5 — every run
#  This guarantees all three DML types appear in every GoldenGate capture cycle.
#  All DML is committed per operation; exceptions roll back silently so the
#  job stays healthy across restarts.
# =============================================================================

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
JOB_NAME="HR_LOAD_JOB"

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
# usage
# ---------------------------------------------------------------------------
usage() {
    echo
    echo -e "${BOLD}Usage:${NC}  $0 [--west | --east | --both] [--create | --drop | --status]"
    echo
    echo "  Targets : --west (default)  --east  --both"
    echo "  Modes   : --create (default)  --drop  --status"
    echo
}

# ---------------------------------------------------------------------------
# create_job <container> <label>
#   Drops the job if it already exists, then creates it fresh.
#
#   Quoting strategy:
#     Outer <<'BASHEOF'  single-quoted — Mac bash sends content verbatim to
#                        the container; no Mac-side variable expansion needed.
#     Inner <<'SQLEOF'   single-quoted — container bash passes SQL/PLSQL
#                        content verbatim to sqlplus.
#     q'[...]'           Oracle q-quoting inside the PLSQL_BLOCK job_action
#                        string, so single quotes inside the job body require
#                        no escaping at all.
# ---------------------------------------------------------------------------
create_job() {
    local container="$1"
    local label="$2"

    print_header "Creating HR Load Job — ${label}"

    if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
        print_error "Container '${container}' is not running. Skipping."
        return 1
    fi

    print_step "Dropping any existing ${JOB_NAME} and creating it fresh in FREEPDB1..."
    echo

    docker exec -u oracle -i "${container}" bash -s <<'BASHEOF'
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET FEEDBACK     OFF
SET DEFINE       OFF

-- Switch to the PDB where HR lives
ALTER SESSION SET CONTAINER = FREEPDB1;

-- Drop the job if it already exists (idempotent)
BEGIN
    DBMS_SCHEDULER.DROP_JOB(job_name => 'HR_LOAD_JOB', force => TRUE);
    DBMS_OUTPUT.PUT_LINE('Existing HR_LOAD_JOB dropped.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27475 THEN
            DBMS_OUTPUT.PUT_LINE('No existing job found — continuing.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('Drop note: ' || SQLERRM);
        END IF;
END;
/

-- Create the job
-- q'[...]' = Oracle alternative quoting — single quotes inside are literal
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HR_LOAD_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
DECLARE
    l_emp_id  NUMBER;
    l_cnt     NUMBER;
BEGIN
    -- 1. UPDATE salary +/-50 for 5 employees (alternating by employee_id parity)
    UPDATE hr.employees
    SET    salary = salary + CASE MOD(employee_id, 2)
                                 WHEN 0 THEN  50
                                 ELSE        -50
                             END
    WHERE  salary BETWEEN 2500 AND 24000
    AND    ROWNUM <= 5;
    COMMIT;

    -- 2. UPDATE phone_number with current timestamp for 3 employees
    UPDATE hr.employees
    SET    phone_number = '555.' ||
                          TO_CHAR(SYSTIMESTAMP, 'MI') || '.' ||
                          TO_CHAR(SYSTIMESTAMP, 'SS') || '.' ||
                          LPAD(employee_id, 4, '0')
    WHERE  ROWNUM <= 3;
    COMMIT;

    -- 3. INSERT one GGLoad test employee every run
    SELECT NVL(MAX(employee_id), 206) + 1
    INTO   l_emp_id
    FROM   hr.employees;

    INSERT INTO hr.employees (
        employee_id, first_name,     last_name,
        email,       hire_date,      job_id,
        salary,      commission_pct, manager_id, department_id
    ) VALUES (
        l_emp_id,
        'GGLoad',
        'Test' || l_emp_id,
        'GGLD'  || l_emp_id,
        SYSDATE,
        'SA_REP',
        5000 + MOD(l_emp_id, 3000),
        0.15,
        145,
        80
    );
    COMMIT;

    -- 4. DELETE the single oldest GGLoad row to keep a rolling window of ~5
    SELECT COUNT(*) INTO l_cnt
    FROM   hr.employees
    WHERE  first_name = 'GGLoad';

    IF l_cnt > 5 THEN
        DELETE FROM hr.employees
        WHERE  employee_id = (
                   SELECT MIN(employee_id)
                   FROM   hr.employees
                   WHERE  first_name = 'GGLoad'
               );
        COMMIT;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;  -- never let an exception disable the job
END;
        ]',
        start_date      => SYSTIMESTAMP + INTERVAL '5' SECOND,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=5',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'GoldenGate continuous load — DML every 5 s on HR schema'
    );
    DBMS_OUTPUT.PUT_LINE('HR_LOAD_JOB created and enabled.');
END;
/

-- Confirm
SET PAGESIZE 10
SET LINESIZE 100
COLUMN job_name        FORMAT A14
COLUMN state           FORMAT A10
COLUMN enabled         FORMAT A8   HEADING 'ENABLED'
COLUMN repeat_interval FORMAT A24
COLUMN next_run_date   FORMAT A34  HEADING 'NEXT RUN'
SELECT JOB_NAME, STATE, ENABLED, REPEAT_INTERVAL, NEXT_RUN_DATE
FROM   DBA_SCHEDULER_JOBS
WHERE  JOB_NAME = 'HR_LOAD_JOB';

EXIT;
SQLEOF
BASHEOF

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        print_ok "${JOB_NAME} is running — DML fires every 5 s on ${label} / FREEPDB1"
    else
        print_warn "Job creation may have issues (exit ${rc}) — review output above"
    fi
}

# ---------------------------------------------------------------------------
# drop_job <container> <label>
# ---------------------------------------------------------------------------
drop_job() {
    local container="$1"
    local label="$2"

    print_header "Dropping HR Load Job — ${label}"

    docker exec -u oracle -i "${container}" bash -s <<'BASHEOF'
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET DEFINE       OFF

ALTER SESSION SET CONTAINER = FREEPDB1;

BEGIN
    DBMS_SCHEDULER.DROP_JOB(job_name => 'HR_LOAD_JOB', force => TRUE);
    DBMS_OUTPUT.PUT_LINE('HR_LOAD_JOB stopped and dropped.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Note: ' || SQLERRM);
END;
/

EXIT;
SQLEOF
BASHEOF

    print_ok "${JOB_NAME} dropped on ${label}"
}

# ---------------------------------------------------------------------------
# stop_job <container> <label>
#   Disables the job (pauses execution) without removing it.
# ---------------------------------------------------------------------------
stop_job() {
    local container="$1"
    local label="$2"

    print_header "Stopping HR Load Job — ${label}"

    docker exec -u oracle -i "${container}" bash -s <<'BASHEOF'
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET DEFINE       OFF

ALTER SESSION SET CONTAINER = FREEPDB1;

BEGIN
    DBMS_SCHEDULER.DISABLE(name => 'HR_LOAD_JOB', force => TRUE);
    DBMS_OUTPUT.PUT_LINE('HR_LOAD_JOB disabled (paused).');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Note: ' || SQLERRM);
END;
/

EXIT;
SQLEOF
BASHEOF

    print_ok "${JOB_NAME} paused on ${label} (definition kept — use --start to resume)"
}

# ---------------------------------------------------------------------------
# start_job <container> <label>
#   Enables a previously disabled job, resuming execution immediately.
# ---------------------------------------------------------------------------
start_job() {
    local container="$1"
    local label="$2"

    print_header "Starting HR Load Job — ${label}"

    docker exec -u oracle -i "${container}" bash -s <<'BASHEOF'
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'SQLEOF'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET SERVEROUTPUT ON
SET DEFINE       OFF

ALTER SESSION SET CONTAINER = FREEPDB1;

BEGIN
    DBMS_SCHEDULER.ENABLE(name => 'HR_LOAD_JOB');
    DBMS_OUTPUT.PUT_LINE('HR_LOAD_JOB enabled (resumed).');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Note: ' || SQLERRM);
END;
/

EXIT;
SQLEOF
BASHEOF

    print_ok "${JOB_NAME} resumed on ${label}"
}

# ---------------------------------------------------------------------------
# show_status <container> <label>
# ---------------------------------------------------------------------------
show_status() {
    local container="$1"
    local label="$2"

    print_header "HR Load Job Status — ${label}"

    docker exec -u oracle -i "${container}" bash -s <<'BASHEOF'
$ORACLE_HOME/bin/sqlplus -S / as sysdba <<'SQLEOF'
SET PAGESIZE  40
SET LINESIZE  110
SET FEEDBACK  OFF
SET ECHO      OFF
SET DEFINE    OFF

ALTER SESSION SET CONTAINER = FREEPDB1;

PROMPT ━━ Job Definition ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN job_name      FORMAT A14
COLUMN state         FORMAT A10
COLUMN enabled       FORMAT A8   HEADING 'ENABLED'
COLUMN run_count     FORMAT 9999 HEADING 'RUNS'
COLUMN failure_count FORMAT 9999 HEADING 'FAILS'
COLUMN next_run_date FORMAT A34  HEADING 'NEXT RUN'
SELECT JOB_NAME, STATE, ENABLED, RUN_COUNT, FAILURE_COUNT, NEXT_RUN_DATE
FROM   DBA_SCHEDULER_JOBS
WHERE  JOB_NAME = 'HR_LOAD_JOB';

PROMPT ━━ Last 5 Executions ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN log_date  FORMAT A22  HEADING 'RUN AT'
COLUMN status    FORMAT A10
COLUMN error#    FORMAT 9999 HEADING 'ERR'
SELECT TO_CHAR(LOG_DATE, 'YYYY-MM-DD HH24:MI:SS') AS log_date,
       STATUS,
       ERROR#
FROM   DBA_SCHEDULER_JOB_LOG
WHERE  JOB_NAME = 'HR_LOAD_JOB'
ORDER  BY LOG_DATE DESC
FETCH  FIRST 5 ROWS ONLY;

PROMPT ━━ HR Row Counts ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COLUMN tbl  FORMAT A15  HEADING 'Table'
COLUMN rows FORMAT 9999 HEADING 'Rows'
SELECT 'EMPLOYEES'   AS tbl, COUNT(*) AS rows FROM hr.employees   UNION ALL
SELECT 'JOB_HISTORY' AS tbl, COUNT(*) AS rows FROM hr.job_history UNION ALL
SELECT 'DEPARTMENTS' AS tbl, COUNT(*) AS rows FROM hr.departments;

EXIT;
SQLEOF
BASHEOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET="--west"
MODE="--create"

for arg in "$@"; do
    case "${arg}" in
        --west)    TARGET="--west"  ;;
        --east)    TARGET="--east"  ;;
        --both)    TARGET="--both"  ;;
        --create)  MODE="--create"  ;;
        --stop)    MODE="--stop"    ;;
        --start)   MODE="--start"   ;;
        --drop)    MODE="--drop"    ;;
        --status)  MODE="--status"  ;;
        --help|-h) usage; exit 0    ;;
        *)
            print_error "Unknown argument: ${arg}"
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
run_mode() {
    local container="$1"
    local label="$2"
    case "${MODE}" in
        --create) create_job  "${container}" "${label}" ;;
        --stop)   stop_job    "${container}" "${label}" ;;
        --start)  start_job   "${container}" "${label}" ;;
        --drop)   drop_job    "${container}" "${label}" ;;
        --status) show_status "${container}" "${label}" ;;
    esac
}

echo
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}  HR Continuous Load — ${MODE/--/}${NC}"
echo -e "${BLUE}${BOLD}  $(date)${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"

case "${TARGET}" in
    --west) run_mode "${CONTAINER_WEST}" "WEST" ;;
    --east) run_mode "${CONTAINER_EAST}" "EAST" ;;
    --both)
        run_mode "${CONTAINER_WEST}" "WEST"
        run_mode "${CONTAINER_EAST}" "EAST"
        ;;
esac

echo
echo -e "${GREEN}${BOLD}  Done.${NC}"
echo
if [[ "${MODE}" == "--create" || "${MODE}" == "--start" ]]; then
    echo "  Manage the job:"
    echo "    Status  :  ./2_generate_load.sh --west --status"
    echo "    Pause   :  ./2_generate_load.sh --west --stop"
    echo "    Resume  :  ./2_generate_load.sh --west --start"
    echo "    Drop    :  ./2_generate_load.sh --west --drop"
    echo "    Rebuild :  ./2_generate_load.sh --west --create"
    echo
fi
