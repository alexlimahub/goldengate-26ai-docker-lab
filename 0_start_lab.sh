#!/bin/bash
# =============================================================================
#  0_start_lab.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Created: 2026-04-18
#  Full lab orchestration script: tears down the current stack, brings it back
#  up, configures both databases, creates GoldenGate replication, and sets up
#  both Veridata agents.
#
#  Usage:  ./0_start_lab.sh
#
#  Steps:
#    1.  docker compose down -v       – clean shutdown + remove named volumes
#    2.  docker compose up -d         – start the full stack detached
#    3.  ./post_compose_setup.sh      – wait for DBs, configure GG params,
#                                       install HR schema, enable ACDR
#    4.  ./3_archivelog_cleanup.sh --setup      – deploy archivelog cron to DB containers
#    5.  ./1_create_replication.sh    – create GoldenGate replication paths
#                                       (waits for GG endpoints internally)
#    6.  ./Veridata/0_check_veridata_agents.sh  – verify agent status before setup
#    7.  ./Veridata/1_create_veridata_agent.sh  – create Veridata agent deployment
#    8.  ./Veridata/0_check_veridata_agents.sh  – confirm agents are running
#    9.  ./Veridata/2_create_veridata_connections.sh  – create WEST + EAST connections
#   10.  ./Veridata/3_create_veridata_profile.sh --scenario all  – create all profiles
#   11.  ./Veridata/4_create_veridata_group_and_pairs.sh         – create HR compare group
#   12.  ./Veridata/5_run_veridata_comparison.sh                 – run initial comparison
#   13.  ./Veridata/6_schedule_veridata_job.sh                   – schedule daily job
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
print_step()    { echo -e "${CYAN}  >>> $1${NC}"; }
print_ok()      { echo -e "${GREEN}  [OK]    $1${NC}"; }
print_warn()    { echo -e "${YELLOW}  [WARN]  $1${NC}"; }
print_error()   { echo -e "${RED}  [ERROR] $1${NC}"; }

# ---------------------------------------------------------------------------
# wait_for_veridata_api
#   Polls the Veridata login endpoint until it returns a valid JWT token.
#   The web server (nginx) comes up before the JVM REST API is ready, so
#   0_wait_for_stack.sh passing is not enough — we need the API itself.
# ---------------------------------------------------------------------------
wait_for_veridata_api() {
    local max_wait=300
    local poll=10
    local elapsed=0
    local url="https://localhost:8831/veridata/v1/auth/login"

    print_header "Waiting for Veridata REST API"
    print_step "Polling ${url} until login succeeds (timeout: ${max_wait}s)..."
    echo

    while true; do
        TOKEN=$(curl -sk -u "veridata:Welcome##123" "${url}" \
                | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        if [[ -n "$TOKEN" ]]; then
            print_ok "Veridata REST API is ready (${elapsed}s)"
            return 0
        fi

        elapsed=$(( elapsed + poll ))
        if (( elapsed >= max_wait )); then
            print_error "Veridata REST API did not become ready after ${max_wait}s"
            return 1
        fi

        echo -e "${YELLOW}  ⏳ Veridata API not ready yet... (${elapsed}s)${NC}"
        sleep ${poll}
    done
}

# ---------------------------------------------------------------------------
# run_step <step_number> <label> <command...>
#   Runs a command, times it, and exits the whole script on failure.
# ---------------------------------------------------------------------------
STEP_TIMES=()   # collects "label|elapsed" for the final summary

run_step() {
    local step_num="$1"
    local label="$2"
    shift 2

    print_header "Step ${step_num}: ${label}"
    print_step "Running: $*"
    echo

    local t0
    t0=$(date +%s)

    # Run the command from SCRIPT_DIR so relative paths always resolve
    (cd "${SCRIPT_DIR}" && "$@")
    local rc=$?

    local elapsed=$(( $(date +%s) - t0 ))

    if [[ ${rc} -ne 0 ]]; then
        echo
        print_error "Step ${step_num} FAILED (exit code ${rc}) after ${elapsed}s — aborting"
        echo
        echo -e "${RED}${BOLD}  Lab setup did not complete. Fix the error above and re-run.${NC}"
        echo
        exit ${rc}
    fi

    STEP_TIMES+=("${step_num}. ${label}|${elapsed}s")
    echo
    print_ok "Step ${step_num} complete (${elapsed}s)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
LAB_START=$(date +%s)

echo
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}  Oracle GoldenGate Lab — Full Stack Start${NC}"
echo -e "${BLUE}${BOLD}  $(date)${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"

run_step 1 "Tear down existing stack (including volumes)" \
    docker compose down -v

run_step 2 "Start full stack (detached)" \
    docker compose up -d

run_step 3 "Database setup — GG params, HR schema, ACDR" \
    bash "${SCRIPT_DIR}/post_compose_setup.sh"

run_step 4 "Archivelog cleanup — deploy cron to containers" \
    bash "${SCRIPT_DIR}/3_archivelog_cleanup.sh" --setup

run_step 5 "GoldenGate replication setup" \
    bash "${SCRIPT_DIR}/1_create_replication.sh"

run_step 6 "Veridata — check agent status (pre-setup)" \
    bash "${SCRIPT_DIR}/Veridata/0_check_veridata_agents.sh"

run_step 7 "Veridata — create agent deployment" \
    bash "${SCRIPT_DIR}/Veridata/1_create_veridata_agent.sh"

run_step 8 "Veridata — confirm agents are running" \
    bash "${SCRIPT_DIR}/Veridata/0_check_veridata_agents.sh"

wait_for_veridata_api || exit 1

run_step 9 "Veridata — create connections (WEST + EAST)" \
    bash "${SCRIPT_DIR}/Veridata/2_create_veridata_connections.sh"

run_step 10 "Veridata — create all comparison profiles" \
    bash "${SCRIPT_DIR}/Veridata/3_create_veridata_profile.sh" --scenario all

run_step 11 "Veridata — create HR compare group and pairs" \
    bash "${SCRIPT_DIR}/Veridata/4_create_veridata_group_and_pairs.sh" \
        --source WEST --target EAST --schema HR \
        --profile HR_PROFILE_MEDIUM --all-tables

run_step 12 "Veridata — run initial HR comparison" \
    bash "${SCRIPT_DIR}/Veridata/5_run_veridata_comparison.sh" \
        --profile HR_PROFILE_MEDIUM --latest-group

run_step 13 "Veridata — schedule daily comparison job" \
    bash "${SCRIPT_DIR}/Veridata/6_schedule_veridata_job.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
LAB_ELAPSED=$(( $(date +%s) - LAB_START ))
LAB_MIN=$(( LAB_ELAPSED / 60 ))
LAB_SEC=$(( LAB_ELAPSED % 60 ))

echo
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Lab is UP!  Total time: ${LAB_MIN}m ${LAB_SEC}s${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo
echo "  Step timings:"
for entry in "${STEP_TIMES[@]}"; do
    label="${entry%%|*}"
    elapsed="${entry##*|}"
    printf "    %-52s %s\n" "${label}" "${elapsed}"
done
echo
echo "  Access:"
echo "    GoldenGate WEST  →  https://localhost:9090  (oggadmin / Welcome##123)"
echo "    GoldenGate EAST  →  https://localhost:8080  (oggadmin / Welcome##123)"
echo "    Veridata         →  https://localhost:8831/veridata  (veridata / Welcome##123)"
echo "    Database WEST    →  localhost:1534/FREEPDB1"
echo "    Database EAST    →  localhost:1535/FREEPDB1"
echo "    Grafana          →  http://localhost:3000"
echo
echo "  Veridata:"
echo "    Re-run comparison  :  ./Veridata/5_run_veridata_comparison.sh --profile HR_PROFILE_MEDIUM --latest-group"
echo "    Check schedule     :  https://localhost:8831/veridata  → Jobs → Schedules"
echo
echo "  Archivelog cleanup (cron every 5 min, inside containers):"
echo "    Status : ./3_archivelog_cleanup.sh --status"
echo "    Logs   : ./3_archivelog_cleanup.sh --logs"
echo
