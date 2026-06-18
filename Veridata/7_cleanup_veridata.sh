#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-04-03
# ─────────────────────────────────────────────────────────────────────────────
# Removes all Veridata Jobs, Compare Groups (and their pairs), and custom
# Profiles via REST API.
#
# Preserved (not deleted):
#   • Connections  (WEST / EAST)
#   • $default profile
#
# Usage:
#   ./7_cleanup_veridata.sh           — interactive confirmation
#   ./7_cleanup_veridata.sh --force   — skip confirmation prompt

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="veridata"
VERIDATA_PASS='Welcome##123'
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"
FORCE=false

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--force]"
      exit 1 ;;
  esac
done

# ─── Login ────────────────────────────────────────────────────────────────────
echo "==> Logging in to Veridata on ${VERIDATA_HOST}:${VERIDATA_PORT}..."
TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
  "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "❌ Login failed. Exiting."
  exit 1
fi
echo "✅ Login successful."
echo ""

# ─── Inventory ───────────────────────────────────────────────────────────────
JOBS_RESP=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "${BASE_URL}/services/configuration/jobs")
GROUPS_RESP=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "${BASE_URL}/services/configuration/groups")
PROFILES_RESP=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "${BASE_URL}/services/configuration/profiles")

# Extract using python3 for reliable parsing
read -r JOB_COUNT JOB_LIST <<< $(echo "$JOBS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', [])
ids = [str(i['id']) for i in items if 'id' in i]
names = [i.get('name','?') for i in items if 'id' in i]
print(len(ids), '|'.join(f\"{i}:{n}\" for i,n in zip(ids,names)))
")

read -r GROUP_COUNT GROUP_LIST <<< $(echo "$GROUPS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', [])
ids = [str(i['id']) for i in items if 'id' in i]
names = [i.get('name','?') for i in items if 'id' in i]
print(len(ids), '|'.join(f\"{i}:{n}\" for i,n in zip(ids,names)))
")

read -r PROFILE_COUNT PROFILE_LIST <<< $(echo "$PROFILES_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', [])
# Exclude \$default (id=1)
items = [i for i in items if i.get('name') != '\$default']
ids = [str(i['id']) for i in items if 'id' in i]
names = [i.get('name','?') for i in items if 'id' in i]
print(len(ids), '|'.join(f\"{i}:{n}\" for i,n in zip(ids,names)))
")

# ─── Preview ─────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Veridata Cleanup Preview                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-56s║\n" "Jobs to delete      : ${JOB_COUNT:-0}"
if [ -n "$JOB_LIST" ]; then
  IFS='|' read -ra JOB_ENTRIES <<< "$JOB_LIST"
  for entry in "${JOB_ENTRIES[@]}"; do
    printf "║    %-54s║\n" "• ${entry#*:}"
  done
fi
printf "║  %-56s║\n" "Groups to delete    : ${GROUP_COUNT:-0}  (pairs deleted with group)"
if [ -n "$GROUP_LIST" ]; then
  IFS='|' read -ra GROUP_ENTRIES <<< "$GROUP_LIST"
  for entry in "${GROUP_ENTRIES[@]}"; do
    printf "║    %-54s║\n" "• ${entry#*:}"
  done
fi
printf "║  %-56s║\n" "Profiles to delete  : ${PROFILE_COUNT:-0}  (\$default preserved)"
if [ -n "$PROFILE_LIST" ]; then
  IFS='|' read -ra PROFILE_ENTRIES <<< "$PROFILE_LIST"
  for entry in "${PROFILE_ENTRIES[@]}"; do
    printf "║    %-54s║\n" "• ${entry#*:}"
  done
fi
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Connections     : preserved (WEST / EAST)               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "${JOB_COUNT:-0}" -eq 0 ] && [ "${GROUP_COUNT:-0}" -eq 0 ] && [ "${PROFILE_COUNT:-0}" -eq 0 ]; then
  echo "  Nothing to clean up. Exiting."
  exit 0
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────
if [ "$FORCE" = false ]; then
  printf "  Proceed with cleanup? [y/N]: "
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "  Cancelled."
    exit 0
  fi
fi
echo ""

# ─── Delete Jobs ─────────────────────────────────────────────────────────────
if [ -n "$JOB_LIST" ]; then
  echo "--- Deleting Jobs ---"
  IFS='|' read -ra JOB_ENTRIES <<< "$JOB_LIST"
  for entry in "${JOB_ENTRIES[@]}"; do
    ID="${entry%%:*}"; NAME="${entry#*:}"
    TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
      "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    HTTP=$(curl -sk -w "%{http_code}" -o /dev/null -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "${BASE_URL}/services/configuration/jobs/${ID}")
    if [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ]; then
      echo "  ✅ Job '${NAME}' (ID: ${ID}) deleted"
    else
      echo "  ⚠️  Job '${NAME}' (ID: ${ID}) — HTTP ${HTTP}"
    fi
  done
  echo ""
fi

# ─── Delete Groups (cascades to compare pairs) ────────────────────────────────
if [ -n "$GROUP_LIST" ]; then
  echo "--- Deleting Groups (and their compare pairs) ---"
  IFS='|' read -ra GROUP_ENTRIES <<< "$GROUP_LIST"
  for entry in "${GROUP_ENTRIES[@]}"; do
    ID="${entry%%:*}"; NAME="${entry#*:}"
    TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
      "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    HTTP=$(curl -sk -w "%{http_code}" -o /dev/null -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "${BASE_URL}/services/configuration/groups/${ID}")
    if [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ]; then
      echo "  ✅ Group '${NAME}' (ID: ${ID}) deleted"
    else
      echo "  ⚠️  Group '${NAME}' (ID: ${ID}) — HTTP ${HTTP}"
    fi
  done
  echo ""
fi

# ─── Delete Profiles (preserve $default) ─────────────────────────────────────
if [ -n "$PROFILE_LIST" ]; then
  echo "--- Deleting Profiles ---"
  IFS='|' read -ra PROFILE_ENTRIES <<< "$PROFILE_LIST"
  for entry in "${PROFILE_ENTRIES[@]}"; do
    ID="${entry%%:*}"; NAME="${entry#*:}"
    TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
      "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    HTTP=$(curl -sk -w "%{http_code}" -o /dev/null -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "${BASE_URL}/services/configuration/profiles/${ID}")
    if [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ]; then
      echo "  ✅ Profile '${NAME}' (ID: ${ID}) deleted"
    else
      echo "  ⚠️  Profile '${NAME}' (ID: ${ID}) — HTTP ${HTTP}"
    fi
  done
  echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "==> Cleanup complete."
echo "    Jobs deleted     : ${JOB_COUNT:-0}"
echo "    Groups deleted   : ${GROUP_COUNT:-0}"
echo "    Profiles deleted : ${PROFILE_COUNT:-0}"
echo "    Connections      : preserved"
