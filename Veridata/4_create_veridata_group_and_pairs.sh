#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Creates a Veridata compare group and pairs via REST API.
#   Connections : selected interactively or via --source / --target
#   Schema      : HR by default, override with --schema
#   Tables      : auto-discovered via sqlplus (container auto-detected), or prompted
#
# Usage:
#   ./4_create_veridata_group_and_pairs.sh
#   ./4_create_veridata_group_and_pairs.sh --source WEST --target EAST --schema HR --profile HR_PROFILE_MEDIUM
#   ./4_create_veridata_group_and_pairs.sh --source WEST --target EAST --schema HR --profile HR_PROFILE_MEDIUM --all-tables
#   ./4_create_veridata_group_and_pairs.sh --db-host 10.0.0.5 --db-port 1521 --db-service orcl --db-pass secret

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/../vdt.env" ]] && source "${SCRIPT_DIR}/../vdt.env"
[[ -f "${SCRIPT_DIR}/../.env"    ]] && source "${SCRIPT_DIR}/../.env"

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="${VDT_ADMINISTRATOR_USER:-veridata}"
VERIDATA_PASS="${VDT_ADMINISTRATOR_PASSWORD:?ERROR: VDT_ADMINISTRATOR_PASSWORD not set. Copy vdt.env.example to vdt.env and set your password.}"
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"

# Oracle source DB — used for dynamic table discovery via sqlplus.
# Note: Veridata connections store the agent URL, not the Oracle DB URL directly.
# These values are used only for sqlplus table discovery; override via parameters below.
DB_CONTAINER=""          # auto-detected from running Docker containers
DB_HOST="172.52.0.103"
DB_HOST_EXPLICIT=false   # set to true when --db-host is passed
DB_PORT="1521"
DB_SERVICE="freepdb1"
DB_SCHEMA_PASS="${ORACLE_PASSWORD:?ERROR: ORACLE_PASSWORD not set. Copy .env.example to .env and set your password.}"

SRC_CONNECTION_NAME=""   # resolved via menu or --source
TGT_CONNECTION_NAME=""   # resolved via menu or --target
SRC_CONNECTION_ID=""
TGT_CONNECTION_ID=""
PROFILE_NAME=""          # resolved via menu or --profile
SCHEMA="HR"
ALL_TABLES=false         # set true via --all-tables to skip the confirmation prompt

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     SRC_CONNECTION_NAME="$2"; shift 2 ;;
    --target)     TGT_CONNECTION_NAME="$2"; shift 2 ;;
    --profile)    PROFILE_NAME="$2";        shift 2 ;;
    --schema)     SCHEMA="$2";              shift 2 ;;
    --all-tables) ALL_TABLES=true;          shift   ;;
    --db-host)    DB_HOST="$2"; DB_HOST_EXPLICIT=true; shift 2 ;;
    --db-port)    DB_PORT="$2";             shift 2 ;;
    --db-service) DB_SERVICE="$2";          shift 2 ;;
    --db-pass)    DB_SCHEMA_PASS="$2";      shift 2 ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--source <conn>] [--target <conn>] [--schema <name>] [--profile <name>]"
      echo "          [--all-tables] [--db-host <host>] [--db-port <port>] [--db-service <svc>] [--db-pass <pass>]"
      exit 1 ;;
  esac
done

# DB_SCHEMA_USER matches the schema owner (Oracle convention)
DB_SCHEMA_USER="$SCHEMA"

# Group name derived from schema + date for uniqueness
GROUP_NAME="${SCHEMA}_COMPARE_$(date +%Y%m%d)"

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

# ─── Step 2: Select source and target connections ────────────────────────────
CONN_RESP=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/services/configuration/connections")

CONN_NAMES=()
CONN_IDS=()
while IFS='|' read -r cid cname; do
  [ -z "$cid" ] && continue
  CONN_IDS+=("$cid")
  CONN_NAMES+=("$cname")
done < <(echo "$CONN_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', [])
    for c in items:
        if 'id' in c and 'name' in c:
            print(str(c['id']) + '|' + str(c['name']))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
")

if [ ${#CONN_NAMES[@]} -eq 0 ]; then
  echo "❌ No connections found. Run 2_create_veridata_connections.sh first."
  exit 1
fi

# ── Select source connection ──────────────────────────────────────────────────
if [ -z "$SRC_CONNECTION_NAME" ]; then
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           Select Source Connection                       ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  for i in "${!CONN_NAMES[@]}"; do
    printf "║   %2d) %-50s ║\n" "$((i+1))" "${CONN_NAMES[$i]}"
  done
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║    0) exit                                               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  printf "  Select source [1-%d, default: 1]: " "${#CONN_NAMES[@]}"
  read -r MENU_CHOICE
  MENU_CHOICE="${MENU_CHOICE:-1}"
  if [ "$MENU_CHOICE" = "0" ]; then echo "  Exiting."; exit 0; fi
  if ! [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] || \
     [ "$MENU_CHOICE" -lt 1 ] || [ "$MENU_CHOICE" -gt "${#CONN_NAMES[@]}" ]; then
    echo "  ❌ Invalid choice. Exiting."; exit 1
  fi
  SRC_CONNECTION_NAME="${CONN_NAMES[$((MENU_CHOICE-1))]}"
  SRC_CONNECTION_ID="${CONN_IDS[$((MENU_CHOICE-1))]}"
  echo "  ✅ Source: ${SRC_CONNECTION_NAME} (ID: ${SRC_CONNECTION_ID})"
  echo ""
else
  for i in "${!CONN_NAMES[@]}"; do
    if [ "${CONN_NAMES[$i]}" = "$SRC_CONNECTION_NAME" ]; then
      SRC_CONNECTION_ID="${CONN_IDS[$i]}"; break
    fi
  done
  if [ -z "$SRC_CONNECTION_ID" ]; then
    echo "  ❌ Source connection '${SRC_CONNECTION_NAME}' not found. Available:"
    for name in "${CONN_NAMES[@]}"; do echo "    • $name"; done
    exit 1
  fi
  echo "--- Source: ${SRC_CONNECTION_NAME} (ID: ${SRC_CONNECTION_ID}) ---"
  echo ""
fi

# ── Select target connection ──────────────────────────────────────────────────
if [ -z "$TGT_CONNECTION_NAME" ]; then
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           Select Target Connection                       ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  for i in "${!CONN_NAMES[@]}"; do
    MARKER=""
    [ "${CONN_NAMES[$i]}" = "$SRC_CONNECTION_NAME" ] && MARKER=" (source)"
    printf "║   %2d) %-50s ║\n" "$((i+1))" "${CONN_NAMES[$i]}${MARKER}"
  done
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║    0) exit                                               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  printf "  Select target [1-%d, default: 2]: " "${#CONN_NAMES[@]}"
  read -r MENU_CHOICE
  MENU_CHOICE="${MENU_CHOICE:-2}"
  if [ "$MENU_CHOICE" = "0" ]; then echo "  Exiting."; exit 0; fi
  if ! [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] || \
     [ "$MENU_CHOICE" -lt 1 ] || [ "$MENU_CHOICE" -gt "${#CONN_NAMES[@]}" ]; then
    echo "  ❌ Invalid choice. Exiting."; exit 1
  fi
  TGT_CONNECTION_NAME="${CONN_NAMES[$((MENU_CHOICE-1))]}"
  TGT_CONNECTION_ID="${CONN_IDS[$((MENU_CHOICE-1))]}"
  echo "  ✅ Target: ${TGT_CONNECTION_NAME} (ID: ${TGT_CONNECTION_ID})"
  echo ""
else
  for i in "${!CONN_NAMES[@]}"; do
    if [ "${CONN_NAMES[$i]}" = "$TGT_CONNECTION_NAME" ]; then
      TGT_CONNECTION_ID="${CONN_IDS[$i]}"; break
    fi
  done
  if [ -z "$TGT_CONNECTION_ID" ]; then
    echo "  ❌ Target connection '${TGT_CONNECTION_NAME}' not found. Available:"
    for name in "${CONN_NAMES[@]}"; do echo "    • $name"; done
    exit 1
  fi
  echo "--- Target: ${TGT_CONNECTION_NAME} (ID: ${TGT_CONNECTION_ID}) ---"
  echo ""
fi

if [ "$SRC_CONNECTION_NAME" = "$TGT_CONNECTION_NAME" ]; then
  echo "  ⚠️  Source and target are the same connection: ${SRC_CONNECTION_NAME}"
  printf "  Continue anyway? [y/N]: "
  read -r WARN_CONFIRM
  [[ ! "$WARN_CONFIRM" =~ ^[Yy] ]] && echo "  Cancelled." && exit 0
  echo ""
fi

# ─── Step 3: Discover tables from schema ─────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Table Discovery — Schema: ${SCHEMA}$(printf '%*s' $((26-${#SCHEMA})) '')║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Querying ${DB_HOST}:${DB_PORT}/${DB_SERVICE} ..."

DISCOVERED_TABLES=()

# ── Find containers with sqlplus, auto-match to source connection ─────────────
if [ -z "$DB_CONTAINER" ]; then
  echo "  Searching for sqlplus across running containers..."
  SP_CONTAINERS=()
  SP_PATHS=()
  for cname in $(docker ps --format '{{.Names}}'); do
    [[ "$cname" == k8s_* ]] && continue
    SQLFOUND=$(docker exec "$cname" \
      find /opt/oracle /u01/app /usr/bin /usr/local/bin -name sqlplus -type f 2>/dev/null \
      | head -1)
    if [ -n "$SQLFOUND" ]; then
      SP_CONTAINERS+=("$cname")
      SP_PATHS+=("$SQLFOUND")
    fi
  done

  if [ ${#SP_CONTAINERS[@]} -eq 0 ]; then
    echo "  ℹ️  sqlplus not found in any container — will prompt for table names."
  elif [ ${#SP_CONTAINERS[@]} -eq 1 ]; then
    DB_CONTAINER="${SP_CONTAINERS[0]}"
    DB_SQLPLUS="${SP_PATHS[0]}"
    echo "  ✅ Found sqlplus in container '${DB_CONTAINER}'"
  else
    # Multiple containers — try to auto-match source connection name
    SRC_UPPER=$(echo "$SRC_CONNECTION_NAME" | tr '[:lower:]' '[:upper:]')
    AUTO_IDX=-1
    for i in "${!SP_CONTAINERS[@]}"; do
      CNAME_UPPER=$(echo "${SP_CONTAINERS[$i]}" | tr '[:lower:]' '[:upper:]')
      if [[ "$CNAME_UPPER" == *"$SRC_UPPER"* ]]; then
        AUTO_IDX=$i
        break
      fi
    done

    if [ "$AUTO_IDX" -ge 0 ]; then
      DB_CONTAINER="${SP_CONTAINERS[$AUTO_IDX]}"
      DB_SQLPLUS="${SP_PATHS[$AUTO_IDX]}"
      echo "  ✅ Auto-matched container '${DB_CONTAINER}' to source '${SRC_CONNECTION_NAME}'"
    else
      echo "  Found sqlplus in ${#SP_CONTAINERS[@]} containers — select one for table discovery:"
      for i in "${!SP_CONTAINERS[@]}"; do
        printf "     %2d) %s\n" "$((i+1))" "${SP_CONTAINERS[$i]}"
      done
      printf "  Select container [1-%d]: " "${#SP_CONTAINERS[@]}"
      read -r SP_CHOICE
      SP_CHOICE="${SP_CHOICE:-1}"
      if ! [[ "$SP_CHOICE" =~ ^[0-9]+$ ]] || \
         [ "$SP_CHOICE" -lt 1 ] || [ "$SP_CHOICE" -gt "${#SP_CONTAINERS[@]}" ]; then
        echo "  ❌ Invalid choice. Exiting."; exit 1
      fi
      DB_CONTAINER="${SP_CONTAINERS[$((SP_CHOICE-1))]}"
      DB_SQLPLUS="${SP_PATHS[$((SP_CHOICE-1))]}"
      echo "  ✅ Selected container '${DB_CONTAINER}'"
    fi

    # Use 127.0.0.1 unless --db-host was explicitly passed (sqlplus co-located with Oracle)
    if [ "$DB_HOST_EXPLICIT" = false ]; then
      DB_HOST="127.0.0.1"
      echo "  ℹ️  Using DB_HOST=127.0.0.1 (local to container). Override with --db-host if needed."
    fi
  fi
fi

SQLPLUS_OUTPUT=""
if [ -n "$DB_CONTAINER" ]; then
  SQLPLUS_OUTPUT=$(docker exec "${DB_CONTAINER}" bash -c "
    echo \"SET PAGESIZE 0 FEEDBACK OFF HEADING OFF ECHO OFF VERIFY OFF
SELECT table_name FROM all_tables
WHERE owner=UPPER('${SCHEMA}') AND table_name NOT LIKE 'DT\$_%'
ORDER BY table_name;
EXIT;\" | \"${DB_SQLPLUS}\" -s '${DB_SCHEMA_USER}/${DB_SCHEMA_PASS}@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}'" \
    2>&1)
fi

while IFS= read -r tbl; do
  [ -n "$tbl" ] && DISCOVERED_TABLES+=("$tbl")
done < <(echo "$SQLPLUS_OUTPUT" | grep -v "^$" | grep -v "^SQL" | grep -v "^ORA-" \
  | grep -v "^SP2-" | grep -v "^ERROR" | grep -v "^bash" | tr -d '\r' \
  | grep -E '^[A-Z_][A-Z0-9_$#]*$' | grep -v '^DT\$_')

if [ ${#DISCOVERED_TABLES[@]} -gt 0 ]; then
  echo "  ✅ Found ${#DISCOVERED_TABLES[@]} tables:"
  echo ""
  for i in "${!DISCOVERED_TABLES[@]}"; do
    printf "     %2d) %s\n" "$((i+1))" "${DISCOVERED_TABLES[$i]}"
  done
  echo ""
  if $ALL_TABLES; then
    echo "  ✅ --all-tables set — including all ${#DISCOVERED_TABLES[@]} tables."
    CONFIRM="Y"
  else
    printf "  Include all ${#DISCOVERED_TABLES[@]} tables? [Y/n]: "
    read -r CONFIRM
    CONFIRM="${CONFIRM:-Y}"
  fi
  if [[ "$CONFIRM" =~ ^[Nn] ]]; then
    echo ""
    echo "  Enter the numbers to include (space-separated, e.g. 1 3 5):"
    printf "  > "
    read -r SELECTIONS
    SELECTED=()
    for n in $SELECTIONS; do
      idx=$((n-1))
      [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DISCOVERED_TABLES[@]}" ] && \
        SELECTED+=("${DISCOVERED_TABLES[$idx]}")
    done
    DISCOVERED_TABLES=("${SELECTED[@]}")
  fi
  SCHEMA_TABLES=("${DISCOVERED_TABLES[@]}")
else
  if [ -n "$SQLPLUS_OUTPUT" ]; then
    echo "  ⚠️  Auto-discovery failed. Details:"
    echo "$SQLPLUS_OUTPUT" | head -5 | sed 's/^/     /'
  else
    echo "  ⚠️  Auto-discovery skipped (sqlplus not found in any running container)."
  fi
  echo ""
  echo "  Enter table names for schema '${SCHEMA}' (space-separated):"
  printf "  [default: EMPLOYEES DEPARTMENTS JOBS JOB_HISTORY LOCATIONS COUNTRIES REGIONS]: "
  read -r USER_TABLES
  if [ -z "$USER_TABLES" ]; then
    SCHEMA_TABLES=("EMPLOYEES" "DEPARTMENTS" "JOBS" "JOB_HISTORY" "LOCATIONS" "COUNTRIES" "REGIONS")
  else
    read -r -a SCHEMA_TABLES <<< "$USER_TABLES"
  fi
fi

echo ""
echo "  ┌─────────────────────────────────────────────────┐"
printf "  │  %-49s│\n" "Group  : ${GROUP_NAME}"
printf "  │  %-49s│\n" "Source : ${SRC_CONNECTION_NAME}"
printf "  │  %-49s│\n" "Target : ${TGT_CONNECTION_NAME}"
printf "  │  %-49s│\n" "Schema : ${SCHEMA}"
printf "  │  %-49s│\n" "Tables : ${#SCHEMA_TABLES[@]} selected"
echo "  └─────────────────────────────────────────────────┘"
echo ""

# ─── Step 4: Select profile ──────────────────────────────────────────────────
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

if [ ${#PROFILE_NAMES[@]} -eq 0 ]; then
  echo "❌ No profiles found. Run 3_create_veridata_profile.sh first."
  exit 1
fi

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
    echo "  ❌ Invalid choice: '$MENU_CHOICE'. Exiting."; exit 1
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
    echo "  ❌ Profile '${PROFILE_NAME}' not found. Available profiles:"
    for name in "${PROFILE_NAMES[@]}"; do echo "    • $name"; done
    exit 1
  fi
  echo "--- Profile: ${PROFILE_NAME} (ID: ${PROFILE_ID}) ---"
  echo ""
fi

# ─── Step 5: Create Group ────────────────────────────────────────────────────
echo "--- Creating group: ${GROUP_NAME} ---"
GROUP_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${BASE_URL}/services/configuration/groups" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\":               \"${GROUP_NAME}\",
    \"description\":        \"${SCHEMA} schema comparison: ${SRC_CONNECTION_NAME} vs ${TGT_CONNECTION_NAME} — profile: ${PROFILE_NAME}\",
    \"sourceConnectionId\": ${SRC_CONNECTION_ID},
    \"targetConnectionId\": ${TGT_CONNECTION_ID},
    \"profileId\":          ${PROFILE_ID}
  }")

GROUP_BODY=$(echo "$GROUP_RESPONSE" | grep -v "HTTP_STATUS:")
GROUP_STATUS=$(echo "$GROUP_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
GROUP_ID=$(echo "$GROUP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [ "$GROUP_STATUS" = "201" ]; then
  echo "  ✅ Group created (HTTP 201) — ID: ${GROUP_ID}"
else
  echo "  ❌ Failed to create group (HTTP $GROUP_STATUS)"
  echo "  Response: $GROUP_BODY"
  exit 1
fi
echo ""

# ─── Step 6: Build compare pairs payload ─────────────────────────────────────
echo "--- Building compare pairs payload for schema: ${SCHEMA} ---"
PAIRS_JSON=""
for TABLE in "${SCHEMA_TABLES[@]}"; do
  PAIR="{
    \"name\":        \"${TABLE}=${TABLE}\",
    \"description\": \"Compare ${SCHEMA}.${TABLE} ${SRC_CONNECTION_NAME} vs ${TGT_CONNECTION_NAME}\",
    \"profileId\":   ${PROFILE_ID},
    \"enabled\":     true,
    \"srcTable\":    {\"name\": \"${TABLE}\", \"schema\": \"${SCHEMA}\"},
    \"tgtTable\":    {\"name\": \"${TABLE}\", \"schema\": \"${SCHEMA}\"}
  }"
  if [ -z "$PAIRS_JSON" ]; then
    PAIRS_JSON="$PAIR"
  else
    PAIRS_JSON="${PAIRS_JSON}, ${PAIR}"
  fi
done

# ─── Step 7: Create Compare Pairs ────────────────────────────────────────────
echo "--- Creating compare pairs in group ID: ${GROUP_ID} ---"
CP_RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${BASE_URL}/services/configuration/cps/group/${GROUP_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"comparePairs\": [ ${PAIRS_JSON} ]}")

CP_BODY=$(echo "$CP_RESPONSE" | grep -v "HTTP_STATUS:")
CP_STATUS=$(echo "$CP_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)

if [ "$CP_STATUS" = "201" ]; then
  echo "  ✅ Compare pairs created (HTTP 201)"
else
  echo "  ❌ Failed to create compare pairs (HTTP $CP_STATUS)"
  echo "  Response: $CP_BODY"
  exit 1
fi

# Extract pair IDs from the create response
CP_IDS=()
while IFS= read -r cpid; do
  CP_IDS+=("$cpid")
done < <(echo "$CP_BODY" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('comparePairs', data.get('items', []))
    for cp in items:
        if 'id' in cp: print(cp['id'])
except Exception as e:
    sys.stderr.write(str(e) + '\n')
")

# ─── Step 8: Assign profile to each compare pair via GET + PUT ───────────────
echo ""
echo "--- Assigning profile '${PROFILE_NAME}' to each compare pair ---"

PUT_OK=0
for CPID in "${CP_IDS[@]}"; do
  # Refresh token to avoid JWT expiry mid-loop
  TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
    "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

  # GET full pair (includes columnMappings required by PUT)
  CP_RAW=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/services/configuration/cps/${CPID}")

  # Set profileId (flat int), remove nested read-only "profile" object,
  # strip delta block when deltaProcessingEnabled is false
  CP_UPDATED=$(echo "$CP_RAW" | python3 -c "
import sys, json
cp = json.load(sys.stdin)
cp['profileId'] = ${PROFILE_ID}
cp.pop('profile', None)
if not cp.get('deltaProcessingEnabled', False):
    cp.pop('delta', None)
print(json.dumps(cp))
")

  PR=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
    -X PUT "${BASE_URL}/services/configuration/cps/${CPID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$CP_UPDATED")
  PS=$(echo "$PR" | grep "HTTP_STATUS:" | cut -d: -f2)
  if [ "$PS" = "200" ]; then
    PUT_OK=$((PUT_OK+1))
  else
    PB=$(echo "$PR" | grep -v "HTTP_STATUS:")
    echo "  ⚠️  Pair ID ${CPID} — PUT returned HTTP ${PS}: $PB"
  fi
done
echo "  ✅ Profile '${PROFILE_NAME}' assigned to ${PUT_OK}/${#CP_IDS[@]} compare pairs"

echo ""
echo "  Pairs created:"
for TABLE in "${SCHEMA_TABLES[@]}"; do
  echo "    • ${SCHEMA}.${TABLE} (${SRC_CONNECTION_NAME})  ↔  ${SCHEMA}.${TABLE} (${TGT_CONNECTION_NAME})"
done

echo ""
echo "==> Done. Group '${GROUP_NAME}' is ready with ${#SCHEMA_TABLES[@]} compare pairs."
echo "    Source  : ${SRC_CONNECTION_NAME} (ID: ${SRC_CONNECTION_ID})"
echo "    Target  : ${TGT_CONNECTION_NAME} (ID: ${TGT_CONNECTION_ID})"
echo "    Profile : ${PROFILE_NAME} (ID: ${PROFILE_ID})"
