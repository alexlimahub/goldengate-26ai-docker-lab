#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Creates (or reuses) a Veridata profile and applies scenario-based tuning.
#
# Usage:
#   ./create_veridata_profile.sh [--scenario <name>] [--profile <name>]
#
# Size-based scenarios (recommended starting point):
#   small          <100k rows/table  — lightweight, low resource usage
#   medium         100k–10M rows     — balanced parallelism and batch sizes
#   large          >10M rows         — maximum throughput, high parallelism
#
# Advanced scenarios:
#   default        Clone $default, no attribute overrides
#   high-oos       Optimized for large number of out-of-sync rows (>10k)
#   db-load        Server-side sort to reduce DB load during compare
#   baseline       Disable COOS for fast initial baseline scan
#   repair         Optimized settings for concurrent repair workloads
#   replication-lag  Delayed COOS to account for replication latency

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="veridata"
VERIDATA_PASS='Welcome##123'
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"

PROFILE_NAME=""        # auto-derived from scenario unless --profile is passed
CUSTOM_PROFILE=false
SCENARIO=""

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --profile)  PROFILE_NAME="$2"; CUSTOM_PROFILE=true; shift 2 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--scenario small|medium|large|default|high-oos|db-load|baseline|repair|replication-lag|all] [--profile <name>]"
      exit 1
      ;;
  esac
done

# ─── Interactive menu if no scenario passed ───────────────────────────────────
if [ -z "$SCENARIO" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        Veridata Profile Scenario Selector                ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  Size-based (recommended starting point):                ║"
  echo "║   1) small       < 100k rows/table — lightweight         ║"
  echo "║      💡 Ideal for lookup/reference tables                ║"
  echo "║   2) medium      100k–10M rows — balanced                ║"
  echo "║      💡 Good starting point for most OLTP tables         ║"
  echo "║   3) large       > 10M rows — max throughput             ║"
  echo "║      ⚠️  Set coos.batch.fetch=true in agent.properties   ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  Advanced scenarios:                                     ║"
  echo "║   4) default        Clone \$default, no overrides         ║"
  echo "║   5) high-oos       Optimized for > 10k OOS rows         ║"
  echo "║      ⚠️  Set coos.batch.fetch=true in agent.properties   ║"
  echo "║   6) db-load        Server-side sort, reduce DB load     ║"
  echo "║      💡 Set SourceTempDirectory/TargetTempDirectory      ║"
  echo "║   7) baseline       Disable COOS for initial scan        ║"
  echo "║      💡 Re-run with high-oos after baseline              ║"
  echo "║   8) repair         Concurrent repair operations         ║"
  echo "║      ⚠️  Disables session-level DB triggers during repair ║"
  echo "║   9) replication-lag  Delayed COOS for replication lag   ║"
  echo "║      💡 Adjust COOSConfirmDelaySecs to match lag         ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║  10) all        Create all profiles at once              ║"
  echo "║   0) exit                                                ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  printf "  Select scenario [1-10, default: 1 (small)]: "
  read -r MENU_CHOICE

  # Default to small on plain Enter
  MENU_CHOICE="${MENU_CHOICE:-1}"

  case "$MENU_CHOICE" in
    0|exit|quit)        echo "  Exiting."; exit 0 ;;
    10|all|ALL)         SCENARIO="all" ;;
    1|small)            SCENARIO="small" ;;
    2|medium)           SCENARIO="medium" ;;
    3|large)            SCENARIO="large" ;;
    4|default)          SCENARIO="default" ;;
    5|high-oos)         SCENARIO="high-oos" ;;
    6|db-load)          SCENARIO="db-load" ;;
    7|baseline)         SCENARIO="baseline" ;;
    8|repair)           SCENARIO="repair" ;;
    9|replication-lag)  SCENARIO="replication-lag" ;;
    *)
      echo "  ❌ Invalid choice: '$MENU_CHOICE'. Exiting."
      exit 1
      ;;
  esac
  echo "  ✅ Selected: ${SCENARIO}"
  echo ""
fi

# ─── Scenario Definitions ─────────────────────────────────────────────────────
# Each scenario builds a JSON attributesList payload
build_attributes() {
  case "$SCENARIO" in

    small)
      # <100k rows per table — lightweight, minimal resource usage
      SCENARIO_DESC="Small compare pairs: <100k rows — lightweight profile"
      ATTRIBUTES='[
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"2"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"1000"},
        {"name":"SortUsing",                        "default":false,"value":"database"},
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"0"}
      ]'
      AGENT_NOTE="💡 Ideal for lookup/reference tables or small transactional tables."
      ;;

    medium)
      # 100k–10M rows per table — balanced settings
      SCENARIO_DESC="Medium compare pairs: 100k-10M rows — balanced profile"
      ATTRIBUTES='[
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"4"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"10000"},
        {"name":"SortUsing",                        "default":false,"value":"database"},
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"30"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"500000"},
        {"name":"COOSRptRptIntervalSecs",            "default":false,"value":"30"},
        {"name":"COOSRptMaxRecsOOS",                "default":false,"value":"500000"}
      ]'
      AGENT_NOTE="💡 Good starting point for most OLTP tables."
      ;;

    large)
      # >10M rows per table — maximum throughput
      SCENARIO_DESC="Large compare pairs: >10M rows — maximum throughput profile"
      ATTRIBUTES='[
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"8"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"50000"},
        {"name":"SortUsing",                        "default":false,"value":"database"},
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"60"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"10000000"},
        {"name":"COOSRptRptIntervalSecs",            "default":false,"value":"60"},
        {"name":"COOSRptMaxRecsOOS",                "default":false,"value":"10000000"},
        {"name":"InitCompHintSrc",                  "default":false,"value":"PARALLEL"},
        {"name":"InitCompHintTarg",                 "default":false,"value":"PARALLEL"}
      ]'
      AGENT_NOTE="⚠️  Also set coos.batch.fetch=true in agent.properties for large OOS datasets."
      ;;

    default)
      SCENARIO_DESC="Default settings cloned from \$default"
      ATTRIBUTES='[]'
      ;;

    high-oos)
      SCENARIO_DESC="Optimized for >10,000 out-of-sync rows"
      ATTRIBUTES='[
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"8"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"50000"},
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"SortUsing",                        "default":false,"value":"server"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"30"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"5000000"},
        {"name":"COOSRptRptIntervalSecs",            "default":false,"value":"30"},
        {"name":"COOSRptMaxRecsOOS",                "default":false,"value":"5000000"}
      ]'
      AGENT_NOTE="⚠️  Also set coos.batch.fetch=true in agent.properties for best results."
      ;;

    db-load)
      SCENARIO_DESC="Server-side sorting to reduce database load"
      ATTRIBUTES='[
        {"name":"SortUsing",                        "default":false,"value":"server"},
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"4"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"10000"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"30"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"500000"}
      ]'
      AGENT_NOTE="💡 Set SourceTempDirectory/TargetTempDirectory to fast local disk if needed."
      ;;

    baseline)
      SCENARIO_DESC="Fast baseline scan — COOS disabled for initial data validation"
      ATTRIBUTES='[
        {"name":"DoCOOSStep",                       "default":false,"value":"false"},
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"8"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"15"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"1000000"}
      ]'
      AGENT_NOTE="💡 Re-run with --scenario high-oos after baseline to confirm and reconcile OOS rows."
      ;;

    repair)
      SCENARIO_DESC="Optimized for concurrent repair operations"
      ATTRIBUTES='[
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"4"},
        {"name":"RepairAfterCompare",               "default":false,"value":"true"},
        {"name":"ConcurrRepairOperations",          "default":false,"value":"8"},
        {"name":"RepairBatchSize",                  "default":false,"value":"10000"},
        {"name":"RepairTransactionSize",            "default":false,"value":"100"},
        {"name":"ProfileDisableDbTriggers",         "default":false,"value":"true"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"10000"}
      ]'
      AGENT_NOTE="⚠️  ProfileDisableDbTriggers=true disables session-level DB triggers during repair."
      ;;

    replication-lag)
      SCENARIO_DESC="Delayed COOS to account for replication latency"
      ATTRIBUTES='[
        {"name":"DoCOOSStep",                       "default":false,"value":"true"},
        {"name":"COOSConfirmDelaySecs",             "default":false,"value":"60"},
        {"name":"COOSConcurrent",                   "default":false,"value":"true"},
        {"name":"COOSBatchSize",                    "default":false,"value":"10000"},
        {"name":"ProfileGeneralMaxParallelCompares","default":false,"value":"4"},
        {"name":"InitCompRptRptIntervalSecs",        "default":false,"value":"30"},
        {"name":"InitCompRptMaxRecsOOS",             "default":false,"value":"500000"}
      ]'
      AGENT_NOTE="💡 Adjust COOSConfirmDelaySecs to match your actual replication lag."
      ;;

    *)
      echo "❌ Unknown scenario: '$SCENARIO'"
      echo "   Size-based : small | medium | large"
      echo "   Advanced   : default | high-oos | db-load | baseline | repair | replication-lag"
      exit 1
      ;;
  esac
}

# ─── Step 1: Login ────────────────────────────────────────────────────────────
echo "==> Logging in to Veridata on ${VERIDATA_HOST}:${VERIDATA_PORT}..."
TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
  "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "❌ Login failed. Exiting."
  exit 1
fi
echo "✅ Login successful."
echo ""

# ─── create_one_profile: create + patch a single scenario ─────────────────────
create_one_profile() {
  local SCEN="$1"
  SCENARIO="$SCEN"
  AGENT_NOTE=""

  # Derive profile name unless overridden by --profile
  if [ "$CUSTOM_PROFILE" = false ]; then
    local SUFFIX
    SUFFIX=$(echo "$SCEN" | tr '[:lower:]-' '[:upper:]_')
    PROFILE_NAME="HR_PROFILE_${SUFFIX}"
  fi

  build_attributes

  # Refresh token
  TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
    "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

  echo "--- Creating profile: ${PROFILE_NAME} (scenario: ${SCEN}) ---"
  PROFILE_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${BASE_URL}/services/configuration/profiles" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":         \"${PROFILE_NAME}\",
      \"description\":  \"${SCENARIO_DESC}\",
      \"copyFromName\": \"\$default\"
    }")

  PROFILE_BODY=$(echo   "$PROFILE_RESPONSE" | grep -v "HTTP_STATUS:")
  PROFILE_STATUS=$(echo "$PROFILE_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
  PROFILE_ID=$(echo     "$PROFILE_BODY" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')

  if [ "$PROFILE_STATUS" = "201" ]; then
    echo "  ✅ Profile created (HTTP 201) — ID: ${PROFILE_ID}"
  elif echo "$PROFILE_BODY" | grep -q "already exists"; then
    echo "  ℹ️  Already exists — looking up ID..."
    PROFILE_ID=$(curl -sk \
      -H "Authorization: Bearer ${TOKEN}" \
      "${BASE_URL}/services/configuration/profiles?name=${PROFILE_NAME}" \
      | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')
    echo "  ✅ Reusing existing profile — ID: ${PROFILE_ID}"
  else
    echo "  ❌ Failed to create profile (HTTP $PROFILE_STATUS)"
    echo "     Response: $PROFILE_BODY"
    return 1
  fi

  if [ "$ATTRIBUTES" = "[]" ]; then
    echo "  ℹ️  Scenario 'default' — no attribute overrides applied."
  else
    PATCH_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
      -X PATCH "${BASE_URL}/services/configuration/profiles/${PROFILE_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"description\":   \"${SCENARIO_DESC}\",
        \"attributesList\": ${ATTRIBUTES}
      }")
    PATCH_BODY=$(echo   "$PATCH_RESPONSE" | grep -v "HTTP_STATUS:")
    PATCH_STATUS=$(echo "$PATCH_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    if [ "$PATCH_STATUS" = "200" ]; then
      echo "  ✅ Attributes applied (HTTP 200)"
      echo "$ATTRIBUTES" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | \
        while read -r attr; do
          VALUE=$(echo "$ATTRIBUTES" | grep -o "\"name\":\"${attr}\"[^}]*\"value\":\"[^\"]*\"" \
            | grep -o '"value":"[^"]*"' | cut -d'"' -f4)
          printf "    %-45s = %s\n" "$attr" "$VALUE"
        done
    else
      echo "  ❌ Failed to apply attributes (HTTP $PATCH_STATUS): $PATCH_BODY"
      return 1
    fi
  fi

  if [ -n "$AGENT_NOTE" ]; then echo "  ${AGENT_NOTE}"; fi
  echo ""
}

# ─── Step 2: Create profile(s) ────────────────────────────────────────────────
ALL_SCENARIOS=(small medium large default high-oos db-load baseline repair replication-lag)

if [ "$SCENARIO" = "all" ]; then
  echo "--- Creating all ${#ALL_SCENARIOS[@]} profiles ---"
  echo ""
  CREATED=0
  for s in "${ALL_SCENARIOS[@]}"; do
    create_one_profile "$s" && CREATED=$((CREATED+1))
  done
  echo "==> Done. Created/updated ${CREATED}/${#ALL_SCENARIOS[@]} profiles."
else
  create_one_profile "$SCENARIO"
  echo "==> Done."
  echo "    Profile Name : ${PROFILE_NAME}"
  echo "    Profile ID   : ${PROFILE_ID}"
  echo "    Scenario     : ${SCENARIO}"
  echo ""
  echo "    Use profileId ${PROFILE_ID} in 4_create_veridata_group_and_pairs.sh"
fi
