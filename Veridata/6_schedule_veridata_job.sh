#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Schedules a Veridata comparison job on a recurring cron schedule.
# Uses 6-field Quartz cron format: seconds minutes hours day month weekday
# Default schedule: "0 0 0 * * ?" = every day at midnight
#
# Usage:
#   ./6_schedule_veridata_job.sh                              (auto-selects latest job)
#   ./6_schedule_veridata_job.sh --job <name>                 (exact job name)
#   ./6_schedule_veridata_job.sh --latest-job                 (explicit: highest job ID)
#   ./6_schedule_veridata_job.sh --job <name> --cron "0 0 6 * * ?"   (custom schedule)
#
# Options:
#   --job        <name>    Exact job name to schedule
#   --latest-job           Auto-select the most recently created job (highest ID)
#   --cron       <expr>    Quartz cron expression (default: "0 0 0 * * ?" = midnight)
#   --help, -h             Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/../vdt.env" ]] && source "${SCRIPT_DIR}/../vdt.env"

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="${VDT_ADMINISTRATOR_USER:-veridata}"
VERIDATA_PASS="${VDT_ADMINISTRATOR_PASSWORD:?ERROR: VDT_ADMINISTRATOR_PASSWORD not set. Copy vdt.env.example to vdt.env and set your password.}"
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"

JOB_NAME=""            # resolved via --job or --latest-job (default)
LATEST_JOB=true        # default: auto-pick latest; set false only when --job is given
CRON="0 0 0 * * ?"    # Daily at midnight (Quartz format); override with --cron

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job)        JOB_NAME="$2"; LATEST_JOB=false; shift 2 ;;
    --latest-job) LATEST_JOB=true;                 shift   ;;
    --cron)       CRON="$2";                        shift 2 ;;
    --help|-h)
      echo ""
      echo "Usage: $0 [--job <name> | --latest-job] [--cron <expr>]"
      echo ""
      echo "  --job        <name>    Exact job name to schedule"
      echo "  --latest-job           Auto-select the most recently created job (default)"
      echo "  --cron       <expr>    Quartz cron expression (default: '0 0 0 * * ?' = midnight)"
      echo ""
      echo "  Quartz cron examples:"
      echo "    '0 0 0 * * ?'     Every day at midnight"
      echo "    '0 0 6 * * ?'     Every day at 06:00"
      echo "    '0 0 */4 * * ?'   Every 4 hours"
      echo "    '0 0 0 ? * MON'   Every Monday at midnight"
      echo ""
      exit 0 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--job <name> | --latest-job] [--cron <expr>]"
      exit 1 ;;
  esac
done

# ─── Step 1: Login ───────────────────────────────────────────────────────────
echo "==> Logging in to Veridata on ${VERIDATA_HOST}:${VERIDATA_PORT}..."
TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
  "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "❌ Login failed. Exiting."
  exit 1
fi
echo "✅ Login successful."
echo ""

# ─── Step 2: Look up Job ─────────────────────────────────────────────────────
ALL_JOBS_RESP=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/services/configuration/jobs")

JOB_NAMES=()
JOB_IDS=()
while IFS='|' read -r jid jname; do
  [ -z "$jid" ] && continue
  JOB_IDS+=("$jid")
  JOB_NAMES+=("$jname")
done < <(echo "$ALL_JOBS_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', [])
    for j in items:
        if 'id' in j and 'name' in j:
            print(str(j['id']) + '|' + str(j['name']))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
")

if [ ${#JOB_IDS[@]} -eq 0 ]; then
  echo "❌ No jobs found. Run 5_run_veridata_comparison.sh first to create one."
  exit 1
fi

if $LATEST_JOB; then
  # Pick the job with the highest numeric ID (most recently created)
  BEST_IDX=0
  BEST_ID="${JOB_IDS[0]}"
  for i in "${!JOB_IDS[@]}"; do
    if (( JOB_IDS[i] > BEST_ID )); then
      BEST_ID="${JOB_IDS[$i]}"
      BEST_IDX=$i
    fi
  done
  JOB_NAME="${JOB_NAMES[$BEST_IDX]}"
  JOB_ID="${JOB_IDS[$BEST_IDX]}"
  echo "--- Job (latest): ${JOB_NAME} (ID: ${JOB_ID}) ---"
  echo ""
else
  # Exact name lookup
  echo "--- Looking up job: ${JOB_NAME} ---"
  for i in "${!JOB_NAMES[@]}"; do
    if [ "${JOB_NAMES[$i]}" = "$JOB_NAME" ]; then
      JOB_ID="${JOB_IDS[$i]}"; break
    fi
  done
  if [ -z "$JOB_ID" ]; then
    echo "  ❌ Job '${JOB_NAME}' not found. Available jobs:"
    for name in "${JOB_NAMES[@]}"; do echo "    • $name"; done
    exit 1
  fi
  echo "  ✅ Found job '${JOB_NAME}' — ID: ${JOB_ID}"
  echo ""
fi

# ─── Step 3: Schedule the Job ────────────────────────────────────────────────
echo "--- Scheduling job '${JOB_NAME}' (ID: ${JOB_ID}) ---"
echo "    Cron: '${CRON}'"
echo ""
SCHED_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${BASE_URL}/services/configuration/schedule/jobs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"COMPARE\",
    \"scheduleDetails\": [
      {
        \"schedulePattern\": \"${CRON}\",
        \"params\": {
          \"jobId\":     ${JOB_ID},
          \"isEnabled\": true
        }
      }
    ]
  }")

SCHED_BODY=$(echo "$SCHED_RESPONSE" | grep -v "HTTP_STATUS:")
SCHED_STATUS=$(echo "$SCHED_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)

if [ "$SCHED_STATUS" = "201" ] || [ "$SCHED_STATUS" = "207" ]; then
  if echo "$SCHED_BODY" | grep -q "\"jobsScheduled\":\[\]"; then
    echo "  ⚠️  Job was NOT scheduled."
    echo "  Reason: $(echo "$SCHED_BODY" | grep -o '"errorMessage":"[^"]*"' | cut -d'"' -f4)"
  else
    echo "  ✅ Job scheduled successfully (HTTP ${SCHED_STATUS})"
    echo "  Job      : ${JOB_NAME} (ID: ${JOB_ID})"
    echo "  Schedule : ${CRON}"
    echo "  Enabled  : true"
  fi
else
  echo "  ❌ Failed to schedule job (HTTP $SCHED_STATUS)"
  echo "  Response: $SCHED_BODY"
  exit 1
fi

echo ""
echo "==> Done. '${JOB_NAME}' is scheduled."
echo "    To update the schedule : PATCH ${BASE_URL}/services/configuration/schedule/jobs"
echo "    To remove the schedule : DELETE ${BASE_URL}/services/configuration/schedule/jobs/${JOB_ID}"
