#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Creates and runs a Veridata comparison job for a selected compare group,
# then polls until completion and shows the final status.
#
# Usage:
#   ./5_run_veridata_comparison.sh                                      (interactive)
#   ./5_run_veridata_comparison.sh --profile <name> --group <name>      (non-interactive, exact name)
#   ./5_run_veridata_comparison.sh --profile <name> --latest-group      (non-interactive, newest group)
#
# Options:
#   --profile      <name>   Veridata profile name (e.g. HR_PROFILE_MEDIUM)
#   --group        <name>   Compare group name    (e.g. HR_COMPARE_20260418)
#   --latest-group          Auto-select the most recently created group (highest ID)
#   --help, -h              Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/../vdt.env" ]] && source "${SCRIPT_DIR}/../vdt.env"

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="${VDT_ADMINISTRATOR_USER:-veridata}"
VERIDATA_PASS="${VDT_ADMINISTRATOR_PASSWORD:?ERROR: VDT_ADMINISTRATOR_PASSWORD not set. Copy vdt.env.example to vdt.env and set your password.}"
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"

GROUP_NAME=""          # resolved via menu, --group, or --latest-group
LATEST_GROUP=false     # set true via --latest-group
JOB_NAME=""            # derived from group name
POLL_INTERVAL=5        # seconds between status checks
PROFILE_NAME=""        # resolved via menu or --profile

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE_NAME="$2"; shift 2 ;;
    --group)         GROUP_NAME="$2";   shift 2 ;;
    --latest-group)  LATEST_GROUP=true; shift   ;;
    --help|-h)
      echo ""
      echo "Usage: $0 [--profile <name>] [--group <name> | --latest-group]"
      echo ""
      echo "  --profile      <name>   Veridata profile name (e.g. HR_PROFILE_MEDIUM)"
      echo "  --group        <name>   Compare group name    (e.g. HR_COMPARE_20260418)"
      echo "  --latest-group          Auto-select the most recently created group"
      echo ""
      echo "  Omit either flag to select interactively from a menu."
      echo ""
      exit 0 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--profile <name>] [--group <name> | --latest-group]"
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

# ─── Step 2: Select profile ──────────────────────────────────────────────────
PROFILES_RESP=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/services/configuration/profiles")

PROFILE_NAMES=()
PROFILE_IDS=()
while IFS='|' read -r pid pname; do
  [ -z "$pid" ] && continue
  PROFILE_IDS+=("$pid")
  PROFILE_NAMES+=("$pname")
done < <(echo "$PROFILES_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', data.get('profiles', []))
    for p in items:
        if 'id' in p and 'name' in p and p['name'] != '\$default':
            print(str(p['id']) + '|' + str(p['name']))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
")

if [ -z "$PROFILE_NAME" ]; then
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           Select a Veridata Profile                      ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  for i in "${!PROFILE_NAMES[@]}"; do
    printf "║   %2d) %-50s ║\n" "$((i+1))" "${PROFILE_NAMES[$i]}"
  done
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║    0) exit                                               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  printf "  Select profile [1-%d, default: 1]: " "${#PROFILE_NAMES[@]}"
  read -r MENU_CHOICE
  MENU_CHOICE="${MENU_CHOICE:-1}"

  if [ "$MENU_CHOICE" = "0" ]; then echo "  Exiting."; exit 0; fi
  if ! [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] || \
     [ "$MENU_CHOICE" -lt 1 ] || [ "$MENU_CHOICE" -gt "${#PROFILE_NAMES[@]}" ]; then
    echo "  ❌ Invalid choice. Exiting."; exit 1
  fi
  PROFILE_NAME="${PROFILE_NAMES[$((MENU_CHOICE-1))]}"
  PROFILE_ID="${PROFILE_IDS[$((MENU_CHOICE-1))]}"
  echo "  ✅ Selected: ${PROFILE_NAME} (ID: ${PROFILE_ID})"
  echo ""
else
  for i in "${!PROFILE_NAMES[@]}"; do
    if [ "${PROFILE_NAMES[$i]}" = "$PROFILE_NAME" ]; then
      PROFILE_ID="${PROFILE_IDS[$i]}"; break
    fi
  done
  if [ -z "$PROFILE_ID" ]; then
    echo "  ❌ Profile '${PROFILE_NAME}' not found."; exit 1
  fi
  echo "--- Profile: ${PROFILE_NAME} (ID: ${PROFILE_ID}) ---"
  echo ""
fi

# ─── Step 3: Select Compare Group ───────────────────────────────────────────
GROUPS_RESP=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/services/configuration/groups")

GROUP_NAMES=()
GROUP_IDS=()
while IFS='|' read -r gid gname; do
  [ -z "$gid" ] && continue
  GROUP_IDS+=("$gid")
  GROUP_NAMES+=("$gname")
done < <(echo "$GROUPS_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', [])
    for g in items:
        if 'id' in g and 'name' in g:
            print(str(g['id']) + '|' + str(g['name']))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
")

if [ ${#GROUP_NAMES[@]} -eq 0 ]; then
  echo "❌ No compare groups found. Run 4_create_veridata_group_and_pairs.sh first."
  exit 1
fi

# --latest-group: pick the entry with the highest numeric ID (most recently created)
if $LATEST_GROUP; then
  BEST_IDX=0
  BEST_ID="${GROUP_IDS[0]}"
  for i in "${!GROUP_IDS[@]}"; do
    if (( GROUP_IDS[i] > BEST_ID )); then
      BEST_ID="${GROUP_IDS[$i]}"
      BEST_IDX=$i
    fi
  done
  GROUP_NAME="${GROUP_NAMES[$BEST_IDX]}"
  GROUP_ID="${GROUP_IDS[$BEST_IDX]}"
  echo "--- Group (latest): ${GROUP_NAME} (ID: ${GROUP_ID}) ---"
  echo ""
elif [ -z "$GROUP_NAME" ]; then
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           Select a Compare Group                         ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  for i in "${!GROUP_NAMES[@]}"; do
    printf "║   %2d) %-50s ║\n" "$((i+1))" "${GROUP_NAMES[$i]}"
  done
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║    0) exit                                               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  printf "  Select group [1-%d, default: 1]: " "${#GROUP_NAMES[@]}"
  read -r MENU_CHOICE
  MENU_CHOICE="${MENU_CHOICE:-1}"

  if [ "$MENU_CHOICE" = "0" ]; then echo "  Exiting."; exit 0; fi
  if ! [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] || \
     [ "$MENU_CHOICE" -lt 1 ] || [ "$MENU_CHOICE" -gt "${#GROUP_NAMES[@]}" ]; then
    echo "  ❌ Invalid choice. Exiting."; exit 1
  fi
  GROUP_NAME="${GROUP_NAMES[$((MENU_CHOICE-1))]}"
  GROUP_ID="${GROUP_IDS[$((MENU_CHOICE-1))]}"
  echo "  ✅ Selected: ${GROUP_NAME} (ID: ${GROUP_ID})"
  echo ""
else
  for i in "${!GROUP_NAMES[@]}"; do
    if [ "${GROUP_NAMES[$i]}" = "$GROUP_NAME" ]; then
      GROUP_ID="${GROUP_IDS[$i]}"; break
    fi
  done
  if [ -z "$GROUP_ID" ]; then
    echo "  ❌ Group '${GROUP_NAME}' not found. Available groups:"
    for name in "${GROUP_NAMES[@]}"; do echo "    • $name"; done
    exit 1
  fi
  echo "--- Group: ${GROUP_NAME} (ID: ${GROUP_ID}) ---"
  echo ""
fi

JOB_NAME="${GROUP_NAME}_JOB"

# ─── Step 4: Create or reuse Job ─────────────────────────────────────────────
echo "--- Creating job: ${JOB_NAME} ---"
JOB_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${BASE_URL}/services/configuration/jobs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\":        \"${JOB_NAME}\",
    \"description\": \"HR comparison job WEST vs EAST\",
    \"profileId\":   ${PROFILE_ID},
    \"groups\":      [${GROUP_ID}]
  }")

JOB_BODY=$(echo "$JOB_RESPONSE" | grep -v "HTTP_STATUS:")
JOB_STATUS=$(echo "$JOB_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
JOB_ID=$(echo "$JOB_BODY" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')

if [ "$JOB_STATUS" = "201" ]; then
  echo "  ✅ Job created (HTTP 201) — ID: ${JOB_ID}"
elif echo "$JOB_BODY" | grep -q "already exists"; then
  echo "  ℹ️  Job already exists — recreating with current group ID..."
  # Delete old job (if supported) or just reuse by looking it up differently
  # Since GET by name returns [], we re-create with a timestamp suffix
  JOB_NAME="${JOB_NAME}_$(date +%s)"
  JOB_RESPONSE2=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${BASE_URL}/services/configuration/jobs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":        \"${JOB_NAME}\",
      \"description\": \"HR comparison job WEST vs EAST\",
      \"profileId\":   ${PROFILE_ID},
      \"groups\":      [${GROUP_ID}]
    }")
  JOB_BODY=$(echo "$JOB_RESPONSE2" | grep -v "HTTP_STATUS:")
  JOB_STATUS=$(echo "$JOB_RESPONSE2" | grep "HTTP_STATUS:" | cut -d: -f2)
  JOB_ID=$(echo "$JOB_BODY" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')
  if [ "$JOB_STATUS" = "201" ]; then
    echo "  ✅ Job created — Name: ${JOB_NAME} | ID: ${JOB_ID}"
  else
    echo "  ❌ Failed to create job (HTTP $JOB_STATUS) — Response: $JOB_BODY"
    exit 1
  fi
else
  echo "  ❌ Failed to create job (HTTP $JOB_STATUS)"
  echo "  Response: $JOB_BODY"
  exit 1
fi
echo ""

# ─── Step 5: Execute Job ─────────────────────────────────────────────────────
echo "--- Executing job ID: ${JOB_ID} ---"
RUN_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${BASE_URL}/services/execution/jobs/${JOB_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"profileId\":  ${PROFILE_ID},
    \"runRepair\":  false,
    \"groups\":     [{\"groupId\": ${GROUP_ID}}]
  }")

RUN_BODY=$(echo "$RUN_RESPONSE" | grep -v "HTTP_STATUS:")
RUN_STATUS=$(echo "$RUN_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
# Response is plain string like "1010/0/0" — extract the leading run ID number
RUN_ID=$(echo "$RUN_BODY" | cut -d/ -f1 | tr -d '"')

if [ "$RUN_STATUS" = "200" ] && [ -n "$RUN_ID" ]; then
  echo "  ✅ Job started (HTTP 200) — Run ID: ${RUN_ID}"
else
  echo "  ❌ Failed to start job (HTTP $RUN_STATUS)"
  echo "  Response: $RUN_BODY"
  exit 1
fi
echo ""

# ─── Step 5: Poll for completion ─────────────────────────────────────────────
echo "--- Polling job status (Job: ${JOB_NAME} | Run ID: ${RUN_ID}) ---"
while true; do
  MONITOR=$(curl -sk \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/services/monitoring/jobs")

  # Filter the entry matching our job ID
  JOB_ENTRY=$(echo "$MONITOR" | grep -o "{[^}]*\"jobId\":${JOB_ID}[^}]*}")

  STATUS=$(echo "$MONITOR" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  IN_SYNC=$(echo "$MONITOR" | grep -o '"comparePairsWithNoOOS":[0-9]*' | head -1 | cut -d: -f2)
  OUT_OF_SYNC=$(echo "$MONITOR" | grep -o '"comparePairsWithOOS":[0-9]*' | head -1 | cut -d: -f2)
  ERRORS=$(echo "$MONITOR" | grep -o '"comparePairsWithErrors":[0-9]*' | head -1 | cut -d: -f2)
  RUNNING=$(echo "$MONITOR" | grep -o '"comparePairsRunning":[0-9]*' | head -1 | cut -d: -f2)
  TOTAL=$(echo "$MONITOR" | grep -o '"comparePairsTotal":[0-9]*' | head -1 | cut -d: -f2)

  echo "  Status: ${STATUS:-unknown}  |  Running: ${RUNNING:-?}/${TOTAL:-?}  |  In-Sync: ${IN_SYNC:-?}  |  Out-of-Sync: ${OUT_OF_SYNC:-?}  |  Errors: ${ERRORS:-?}"

  case "$STATUS" in
    "INSYNC"|"OUTOFSYNC"|"COMPLETED"|"ERROR"|"ABORTED"|"CANCELLED")
      break
      ;;
  esac

  sleep $POLL_INTERVAL
done

echo ""
echo "==> Job completed"
echo "    Status      : ${STATUS}"
echo "    In-Sync     : ${IN_SYNC:-0}"
echo "    Out-of-Sync : ${OUT_OF_SYNC:-0}"
echo "    Errors      : ${ERRORS:-0}"

case "$STATUS" in
  "INSYNC"|"COMPLETED")
    echo ""
    echo "✅ All tables are in sync!"
    ;;
  "OUTOFSYNC")
    echo ""
    echo "⚠️  Out-of-sync rows detected. Review in the Veridata UI: https://${VERIDATA_HOST}:${VERIDATA_PORT}"
    ;;
  "ERROR"|"ABORTED"|"CANCELLED")
    echo ""
    echo "❌ Job ended with status: ${STATUS}. Check the Veridata UI for details."
    ;;
esac
