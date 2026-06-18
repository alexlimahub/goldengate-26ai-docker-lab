#!/bin/bash
# =============================================================================
#  initial_load.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Purpose: Automate GoldenGate Initial Load via REST API
#
#  Uses the exact same configuration, variable names, process names, and
#  API patterns as 1_create_replication.sh.
#
#  Two-hub architecture (WEST GG + EAST GG):
#    Change pipeline : EWEST → trail ew → DPWE → trail dw → RWEST → EAST DB
#    Init pipeline   : EINIT → trail ei → DPEI → trail di → RINIT → EAST DB
#
#  Workflow:
#    CLEANUP  - Stop & delete existing RWEST, DPWE, EWEST (and any leftover
#               RINIT, DPEI, EINIT from a previous initial load run)
#    Step 3   - Disable FK constraints on target DB + truncate HR tables
#    Step 5   - Recreate change Extract (EWEST) on WEST GG — start it
#    Step 5b  - Copy wallet + create change Dist Path (DPWE) on WEST GG — start it
#               (delta changes start flowing to EAST immediately while init load runs)
#    Step 6   - Create change Replicat (RWEST) on EAST GG — DO NOT START
#    Step 7   - Capture SCN from source (WEST) DB
#    Step 8   - Create Initial Load Extract (EINIT) on WEST GG — start it
#               (EXTTRAIL ei, SQLPREDICATE AS OF SCN)
#    Step 8b  - Create Initial Load Dist Path (DPEI) on WEST GG — start it
#               (sends ei trail from WEST to EAST as di)
#    Step 8c  - Wait for EINIT to self-stop, then verify DPEI source-read
#               position has reached EINIT's final seq/RBA before continuing
#    Step 9   - Create & start Initial Load Replicat (RINIT) on EAST GG
#    Step 9b  - Poll RINIT read position until it reaches DPEI target-write
#               seq/RBA (RINIT is integrated and will NOT self-stop)
#               Then explicitly stop RINIT
#    Step 9c  - Re-enable FK constraints on target DB
#    Step 10  - Start change Replicat (RWEST) at captured SCN
#               (reads dw trail which has been accumulating since Step 5b)
#
#  Usage (standalone or called from 1_create_replication.sh):
#    ./initial_load.sh
# =============================================================================

set -euo pipefail

start_time=$(date +%s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/goldengate_setup.log"

# ── Load environment (same as 1_create_replication.sh) ───────────────────────
source "$SCRIPT_DIR/.env"

# ── Global variables (identical to 1_create_replication.sh) ──────────────────
GLOBAL_PASS=$OGG_ADMIN_PWD
OGG_USER="oggadmin"

# ── Process definitions (identical to 1_create_replication.sh) ───────────────
conn_properties=("WEST:$DOCKER_DB_WEST_IP:localhost" "EAST:$DOCKER_DB_EAST_IP:localhost")
extract_properties=("WEST:EWEST:ew:localhost")
distpath_properties=("WEST:DPWE:ew:localhost:$DOCKER_OGG_EAST_IP:dw")
replicat_properties=("EAST:RWEST:localhost:dw")

# ── Initial load process definitions ─────────────────────────────────────────
EXTRACT_INIT="EINIT"
TRAIL_INIT="ei"             # trail written by EINIT on WEST GG
TRAIL_INIT_REMOTE="di"      # trail name on EAST GG after DPEI forwards it
DISTPATH_INIT="DPEI"
REPLICAT_INIT="RINIT"
TRAIL_INIT_SIZE_MB=250
CHECKPOINT_TABLE="oggadmin.checkpoints"

# ── Poll settings ─────────────────────────────────────────────────────────────
POLL_INTERVAL=15            # seconds between status checks
POLL_TIMEOUT=1800           # max wait per phase in seconds (30 min)
                            # EINIT can take minutes for large schemas; RINIT
                            # similarly; raise for very large tables if needed


# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS  (same patterns as 1_create_replication.sh)
# ─────────────────────────────────────────────────────────────────────────────

print_step() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════"
}

print_ok()   { echo "  ✔  $1"; }
print_warn() { echo "  ⚠  $1"; }
print_err()  { echo "  ✘  $1" >&2; }

# get_ogg_port <region>
# Sets ogg_port (Admin Server) and ogg_port_deployment (Receiver Server)
# for the given region.  All process management APIs (/services/v2/...) go to
# the Admin Server port.  The Receiver Server port (9014 on EAST) is used by
# the distribution path target URI — hardcoded in the dist path payloads.
get_ogg_port() {
    case $1 in
        "WEST") ogg_port="9090"; ogg_port_deployment="9091" ;;
        "EAST") ogg_port="8080"; ogg_port_deployment="8081" ;;
        *) echo "Invalid region: $1"; exit 1 ;;
    esac
}

# api_call <METHOD> <URL> [JSON_BODY]
api_call() {
    local method=$1
    local url=$2
    local data=${3:-}

    local curl_args=(-s -o response.json -w "%{http_code}" -k -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -u "$OGG_USER:$GLOBAL_PASS")

    [[ -n "$data" ]] && curl_args+=(-d "$data")

    local http_status
    http_status=$(curl "${curl_args[@]}")
    local json_response
    json_response=$(cat response.json)

    if [[ "$http_status" -ne 200 && "$http_status" -ne 201 && "$http_status" -ne 202 ]]; then
        echo "Error: API call failed for $url (HTTP $http_status). Response:" | tee -a "$LOG_FILE"
        echo "$json_response" | tee -a "$LOG_FILE"
    else
        echo "$json_response" | jq '.'
    fi
}

# fetch_json <URL>  — returns the raw JSON body
fetch_json() {
    curl -s -k -u "$OGG_USER:$GLOBAL_PASS" "$1"
}

# get_process_status <kind> <name> <host> <port>
get_process_status() {
    local kind=$1 name=$2 host=$3 port=$4
    local http_status
    http_status=$(curl -s -o response.json -w "%{http_code}" -k \
        -u "$OGG_USER:$GLOBAL_PASS" \
        "https://$host:$port/services/v2/${kind}/${name}")
    if [[ "$http_status" == "404" ]]; then
        echo "NOT_FOUND"
    else
        jq -r '.response.status // .status // "UNKNOWN"' response.json 2>/dev/null || echo "UNKNOWN"
    fi
}

# stop_and_delete <kind> <name> <host> <port>
stop_and_delete() {
    local kind=$1 name=$2 host=$3 port=$4
    local status
    status=$(get_process_status "$kind" "$name" "$host" "$port")

    if [[ "$status" == "NOT_FOUND" ]]; then
        print_warn "$name not found — skipping."
        return 0
    fi

    # Stop process — method varies by type:
    #   extracts / replicats : POST /command {"command":"STOP"}   (GG 23.26 /command endpoint)
    #   sources (dist paths) : PATCH {"status":"stopped"}         (no /command endpoint for sources)
    local status_up
    status_up=$(echo "$status" | tr '[:lower:]' '[:upper:]')
    if [[ "$status_up" == "ABENDED" ]]; then
        print_warn "$name is ABENDED — skipping stop, proceeding to delete."
    elif [[ "$status_up" != "STOPPED" ]]; then
        echo "  Stopping $name (current: $status)..."
        if [[ "$kind" == "sources" ]]; then
            curl -s -o /dev/null -k -X PATCH \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -u "$OGG_USER:$GLOBAL_PASS" \
                -d '{"status":"stopped"}' \
                "https://$host:$port/services/v2/${kind}/${name}"
        else
            curl -s -o /dev/null -k -X POST \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -u "$OGG_USER:$GLOBAL_PASS" \
                -d '{"command":"STOP","isReported":false}' \
                "https://$host:$port/services/v2/${kind}/${name}/command"
        fi

        # Poll until stopped (integrated replicats can take up to 60s)
        local sw=0
        while [[ $sw -lt 120 ]]; do
            sleep 3; sw=$((sw + 3))
            local s
            s=$(get_process_status "$kind" "$name" "$host" "$port")
            local su
            su=$(echo "$s" | tr '[:lower:]' '[:upper:]')
            print_ok "  $name status: $s"
            [[ "$su" == "STOPPED" || "$su" == "NOT_FOUND" || "$su" == "ABENDED" ]] && break
        done
    fi

    echo "  Deleting $name..."
    api_call "DELETE" "https://$host:$port/services/v2/${kind}/${name}" > /dev/null

    # GoldenGate deletes asynchronously — poll until NOT_FOUND
    local waited=0
    while [[ $waited -lt 60 ]]; do
        local check
        check=$(get_process_status "$kind" "$name" "$host" "$port")
        [[ "$check" == "NOT_FOUND" ]] && break
        sleep 3
        waited=$((waited + 3))
    done
    if [[ $waited -ge 60 ]]; then
        print_err "$name still exists after 60s — cannot continue."
        exit 1
    fi
    print_ok "$name deleted."
}

# wait_for_stopped <kind> <name> <host> <port>
wait_for_stopped() {
    local kind=$1 name=$2 host=$3 port=$4
    local elapsed=0
    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
        local status
        status=$(get_process_status "$kind" "$name" "$host" "$port")
        print_ok "$name status: $status"
        local STATUS_UP
        STATUS_UP=$(echo "$status" | tr '[:lower:]' '[:upper:]')
        case "$STATUS_UP" in
            STOPPED) return 0 ;;
            NOT_FOUND)
                print_err "$name disappeared — creation likely failed. Check GoldenGate WebUI."
                exit 1 ;;
            ABENDED)
                print_err "$name ABENDED — check the report file in GoldenGate WebUI."
                exit 1 ;;
        esac
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    print_err "Timeout: $name did not stop within ${POLL_TIMEOUT}s."
    exit 1
}

# run_sql_as_sysdba <container> <pdb_name> <sql>
# Connects via OS auth (/ as sysdba) then switches to the PDB.
# oggadmin does not have ALTER ANY TABLE / TRUNCATE ANY TABLE — must use sysdba.
run_sql_as_sysdba() {
    local container=$1 pdb=$2 sql=$3
    docker exec -u oracle -i "$container" bash -s <<BASHEOF
\$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" <<SQLEOF
SET FEEDBACK OFF ECHO ON
ALTER SESSION SET CONTAINER=$pdb;
$sql
EXIT;
SQLEOF
BASHEOF
}

# delete_trail_files <container> <trail_abbrev> [<trail_abbrev2> ...]
# Removes all trail files matching the given abbreviations from the GG data
# directory (/u02/Deployment/var/lib/data/).  Uses a precise pattern
# ({abbrev}[0-9]*) scoped to that directory so wallet files (ewallet.*) are
# never touched.
delete_trail_files() {
    local container=$1
    shift
    local trails=("$@")

    for trail in "${trails[@]}"; do
        local count
        count=$(docker exec "$container" bash -c \
            "find /u02/Deployment/var/lib/data/ -maxdepth 1 -name '${trail}[0-9]*' -type f 2>/dev/null | wc -l")
        count=$(echo "$count" | tr -d '[:space:]')

        if [[ "$count" -eq 0 ]]; then
            print_warn "No trail files found for '$trail' in $container — skipping."
            continue
        fi

        echo "  Deleting $count trail file(s) for '$trail' in $container..."
        docker exec "$container" bash -c \
            "find /u02/Deployment/var/lib/data/ -maxdepth 1 -name '${trail}[0-9]*' -type f -delete"
        print_ok "Trail '$trail' files deleted from $container."
    done
}


# ─────────────────────────────────────────────────────────────────────────────
# POSITION FUNCTIONS
# Confirmed field paths for GoldenGate 23.26:
#   Extract write pos  → GET /services/v2/extracts/{name}/info/checkpoints
#                        .response.current.output[0].current.{sequence, offset}
#   Dist path lag      → GET /services/{deployment}/distsrvr/v2/sources/{name}/info
#                        .response.lag   (0 = fully caught up)
#   Replicat read pos  → GET /services/v2/replicats/{name}/info/status
#                        .response.position.{sequence, offset}
#   RINIT target seq   → last di trail file sequence on EAST container filesystem
# ─────────────────────────────────────────────────────────────────────────────

# get_extract_write_pos <name> <host> <port>
# Returns "<seq> <offset>" for the last trail position written by the extract.
get_extract_write_pos() {
    local name=$1 host=$2 port=$3
    local json
    json=$(fetch_json "https://$host:$port/services/v2/extracts/$name/info/checkpoints")

    local seq offset
    seq=$(echo    "$json" | jq -r '.response.current.output[0].current.sequence // empty')
    offset=$(echo "$json" | jq -r '.response.current.output[0].current.offset   // empty')

    if [[ -z "$seq" || -z "$offset" ]]; then
        print_err "Could not parse write position for $name. Raw checkpoint response:"
        echo "$json" | jq '.' | head -30
        exit 1
    fi
    echo "$seq $offset"
}

# get_distpath_lag <name> <deployment> <host> <port>
# Returns the lag (seconds) from the distribution server info endpoint.
# Lag == 0 means the path has forwarded all available trail data.
get_distpath_lag() {
    local name=$1 deployment=$2 host=$3 port=$4
    fetch_json "https://$host:$port/services/$deployment/distsrvr/v2/sources/$name/info" | \
        jq -r '.response.lag // 999'
}

# get_replicat_read_pos <name> <host> <port>
# Returns "<seq> <offset>" for the replicat's current read position.
get_replicat_read_pos() {
    local name=$1 host=$2 port=$3
    local json
    json=$(fetch_json "https://$host:$port/services/v2/replicats/$name/info/status")

    local seq offset
    seq=$(echo    "$json" | jq -r '.response.position.sequence // 0')
    offset=$(echo "$json" | jq -r '.response.position.offset   // 0')
    echo "$seq $offset"
}

# get_max_trail_seq <container> <trail_abbrev>
# Returns the highest numeric sequence of trail files on the container filesystem.
get_max_trail_seq() {
    local container=$1 trail=$2
    local last_file
    last_file=$(docker exec "$container" bash -c \
        "ls /u02/Deployment/var/lib/data/${trail}[0-9]* 2>/dev/null | sort | tail -1")
    if [[ -z "$last_file" ]]; then
        echo "0"
        return
    fi
    # Strip path and leading zeros from the numeric suffix
    local seq
    seq=$(basename "$last_file" | sed "s/^${trail}0*//" | tr -d '[:space:]')
    echo "${seq:-0}"
}

# wait_dpei_caught_up
# Polls DPEI lag until it reaches 0, confirming all ei trail data is on EAST.
wait_dpei_caught_up() {
    local elapsed=0
    get_ogg_port "WEST"
    local west_port=$ogg_port

    print_ok "Polling $DISTPATH_INIT lag until 0 (confirms all trail $TRAIL_INIT data forwarded to EAST)..."

    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
        local lag
        lag=$(get_distpath_lag "$DISTPATH_INIT" "WEST" "localhost" "$west_port")
        print_ok "$DISTPATH_INIT lag: ${lag}s"

        if [[ "$lag" -eq 0 ]]; then
            print_ok "$DISTPATH_INIT has forwarded all initial load data to EAST (trail $TRAIL_INIT_REMOTE)."
            return 0
        fi

        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    print_err "Timeout: $DISTPATH_INIT did not reach lag=0 within ${POLL_TIMEOUT}s."
    exit 1
}

# wait_rinit_caught_up
# Polls RINIT's read position until its sequence reaches the last di trail file
# on EAST and the position is stable across two consecutive polls.
# RINIT is integrated and will NOT self-stop — caller must stop it explicitly.
wait_rinit_caught_up() {
    get_ogg_port "EAST"
    local east_port=$ogg_port
    local elapsed=0

    # Find the last di sequence DPEI wrote to EAST
    local max_di_seq
    max_di_seq=$(get_max_trail_seq "oggEAST" "$TRAIL_INIT_REMOTE")
    print_ok "Last $TRAIL_INIT_REMOTE trail sequence on EAST: $max_di_seq"
    print_ok "Waiting for $REPLICAT_INIT to reach seq $max_di_seq and stabilise..."
    print_warn "$REPLICAT_INIT will NOT self-stop — will be stopped explicitly once verified."

    local prev_seq="-1"

    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
        local status
        status=$(get_process_status "replicats" "$REPLICAT_INIT" "localhost" "$east_port")
        if [[ "$(echo "$status" | tr '[:lower:]' '[:upper:]')" == "ABENDED" ]]; then
            print_err "$REPLICAT_INIT ABENDED — check the report file in GoldenGate WebUI."
            exit 1
        fi

        local pos cur_seq cur_offset
        pos=$(get_replicat_read_pos "$REPLICAT_INIT" "localhost" "$east_port")
        read -r cur_seq cur_offset <<< "$pos"

        print_ok "$REPLICAT_INIT position → seq=$cur_seq offset=$cur_offset  (target: seq=$max_di_seq)"

        # Done when sequence has reached the last di trail file AND is no longer
        # advancing (stable across two consecutive polls = all records applied)
        if [[ "$cur_seq" -ge "$max_di_seq" && "$cur_seq" == "$prev_seq" ]]; then
            print_ok "$REPLICAT_INIT has applied all initial load records (seq=$cur_seq, stable)."
            return 0
        fi

        prev_seq=$cur_seq
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    print_err "Timeout: $REPLICAT_INIT did not complete within ${POLL_TIMEOUT}s."
    exit 1
}


# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP — Stop & delete existing pipeline + any leftover initial load processes
# ─────────────────────────────────────────────────────────────────────────────
print_step "CLEANUP: Removing existing pipeline and initial load processes"

# Reverse dependency order: Replicat → Dist Path → Extract

echo "--- Change pipeline ---"
for replicat in "${replicat_properties[@]}"; do
    IFS=':' read -r region_name replicat_name ogg_ip replicat_file <<< "$replicat"
    get_ogg_port "$region_name"
    echo "Checking $replicat_name on $region_name..."
    stop_and_delete "replicats" "$replicat_name" "$ogg_ip" "$ogg_port"
done

for dp in "${distpath_properties[@]}"; do
    IFS=':' read -r region_name dp_name extract_file ogg_ip ogg_ip_remote dp_filename <<< "$dp"
    get_ogg_port "$region_name"
    echo "Checking $dp_name on $region_name..."
    stop_and_delete "sources" "$dp_name" "$ogg_ip" "$ogg_port"
done

for extract in "${extract_properties[@]}"; do
    IFS=':' read -r region_name extract_name extract_file ogg_ip <<< "$extract"
    get_ogg_port "$region_name"
    echo "Checking $extract_name on $region_name..."
    stop_and_delete "extracts" "$extract_name" "$ogg_ip" "$ogg_port"
done

echo "--- Initial load leftover cleanup ---"
get_ogg_port "EAST"; east_port=$ogg_port
get_ogg_port "WEST"; west_port=$ogg_port

echo "Checking leftover $REPLICAT_INIT on EAST..."
stop_and_delete "replicats" "$REPLICAT_INIT" "localhost" "$east_port"

echo "Checking leftover $DISTPATH_INIT on WEST..."
stop_and_delete "sources" "$DISTPATH_INIT" "localhost" "$west_port"

echo "Checking leftover $EXTRACT_INIT on WEST..."
stop_and_delete "extracts" "$EXTRACT_INIT" "localhost" "$west_port"

sleep 3

echo "--- Trail file cleanup ---"
# WEST GG: change trail (ew) + initial load trail (ei)
delete_trail_files "oggWEST" "ew" "ei"
# EAST GG: change dist-path trail (dw) + initial load dist-path trail (di)
delete_trail_files "oggEAST" "dw" "di"


# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Disable FK constraints and truncate target HR tables
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 3: Disable FK constraints + truncate HR tables on TARGET (EAST) DB"

run_sql_as_sysdba "dbEAST" "FREEPDB1" \
    "
-- JOB_HISTORY is a GoldenGate CDC tombstone table (allColumns supplemental logging).
-- Oracle blocks ALTER TABLE constraint ops on it (ORA-26990), so we truncate it first
-- (safe — nothing has a FK pointing to JOB_HISTORY), then disable the remaining FKs.
TRUNCATE TABLE HR.JOB_HISTORY;

BEGIN
  FOR c IN (
    SELECT c.constraint_name, c.table_name
    FROM   all_constraints c
    WHERE  c.owner = 'HR'
    AND    c.constraint_type = 'R'
    AND    c.status = 'ENABLED'
    AND    c.table_name != 'JOB_HISTORY'
    ORDER BY c.table_name
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE HR.' || c.table_name
                     || ' DISABLE CONSTRAINT ' || c.constraint_name;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = -26990 THEN NULL;  -- skip CDC tombstone tables
        ELSE RAISE;
        END IF;
    END;
  END LOOP;
END;
/

TRUNCATE TABLE HR.EMPLOYEES;
TRUNCATE TABLE HR.DEPARTMENTS;
TRUNCATE TABLE HR.LOCATIONS;
TRUNCATE TABLE HR.COUNTRIES;
TRUNCATE TABLE HR.JOBS;
TRUNCATE TABLE HR.REGIONS;
"

print_ok "Constraints disabled and tables truncated on EAST DB."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Create change Extract (EWEST) — identical to 1_create_replication.sh
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 5: Create change Extract (EWEST) on WEST GG"

for extract in "${extract_properties[@]}"; do
    IFS=':' read -r region_name extract_name extract_file ogg_ip <<< "$extract"
    get_ogg_port "$region_name"

    echo "Creating Extract $extract_name on $region_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/extracts/$extract_name" \
        '{
            "description": "Extract Demo",
            "config": [
                "EXTRACT '$extract_name'",
                "ENCRYPTTRAIL AES256",
                "EXTTRAIL '$extract_file'",
                "USERIDALIAS '$region_name' DOMAIN OracleGoldenGate",
                "TRANLOGOPTIONS EXCLUDETAG 00",
                "DDL INCLUDE MAPPED",
                "TABLE HR.*;"
            ],
            "source": "tranlogs",
            "credentials": {"alias": "'$region_name'"},
            "registration": "default",
            "begin": "now",
            "targets": [{"name": "'$extract_file'", "sizeMB": 1}],
            "critical": false,
            "managedProcessSettings": "'$region_name'-profile",
            "encryptionProfile": "LocalWallet",
            "status": "running"
        }'
    print_ok "$extract_name created and started."
done


# ─────────────────────────────────────────────────────────────────────────────
# STEP 5b — Copy wallet + create change Dist Path (DPWE)
#            MUST start now so delta changes accumulate on EAST during init load
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 5b: Copy wallet + create change Dist Path (DPWE) on WEST GG"

echo "Copying encryption wallet from oggWEST to oggEAST..."
docker cp oggWEST:/u02/Deployment/var/lib/wallet/cwallet.sso .
docker cp ./cwallet.sso oggEAST:/u02/Deployment/var/lib/wallet/cwallet.sso
docker exec -u 0 oggEAST chown 1001:root /u02/Deployment/var/lib/wallet/cwallet.sso
print_ok "Wallet copied to EAST."

for dp in "${distpath_properties[@]}"; do
    IFS=':' read -r region_name dp_name extract_file ogg_ip ogg_ip_remote dp_filename <<< "$dp"
    get_ogg_port "$region_name"

    echo "Creating Distribution Path $dp_name on $region_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/sources/$dp_name" \
        '{
            "name": "'$dp_name'",
            "description": "DIST PATH '$dp_name'",
            "source": {"uri": "trail://'$ogg_ip'/services/'$region_name'/distsrvr/v2/sources?trail='$extract_file'"},
            "target": {
                "uri": "ws://'$ogg_ip_remote':9014/services/v2/targets?trail='$dp_filename'",
                "authenticationMethod": {"domain": "Network", "alias": "oggnet"},
                "details": {
                    "trail": {"seqLength": 9, "sizeMB": 1},
                    "compression": {"enabled": true}
                }
            },
            "begin": {"sequence": 0, "offset": 0},
            "encryptionProfile": "LocalWallet",
            "status": "running"
        }'
    print_ok "$dp_name created and started — delta changes now flowing to EAST."
done


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Create change Replicat (RWEST) on EAST GG — DO NOT START
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 6: Create change Replicat (RWEST) on EAST GG — stopped"

for replicat in "${replicat_properties[@]}"; do
    IFS=':' read -r region_name replicat_name ogg_ip replicat_file <<< "$replicat"
    get_ogg_port "$region_name"

    echo "Creating Replicat $replicat_name on $region_name (stopped)..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/replicats/$replicat_name" \
        '{
            "description": "Replicat Demo",
            "config": [
                "REPLICAT '$replicat_name'",
                "USERIDALIAS '$region_name' DOMAIN OracleGoldenGate",
                "DDL INCLUDE MAPPED",
                "MAP hr.*, TARGET hr.*;"
            ],
            "credentials": {"alias": "'$region_name'"},
            "mode": {"parallel": true, "type": "nonintegrated"},
            "source": {"name": "'$replicat_file'"},
            "checkpoint": {"table": "oggadmin.checkpoints"},
            "managedProcessSettings": "'$region_name'-profile"
        }'
    print_ok "$replicat_name created (stopped — will start at Step 10 with SCN)."
done


# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Capture SCN from source (WEST) DB
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 7: Capture SCN from source (WEST) DB"

# Prefer the oldest active transaction's START_SCN over current_scn.
# This ensures in-flight transactions at snapshot time are fully captured
# by the initial load.  Falls back to current_scn when no transactions are active.
SCN=$(docker exec -u oracle -i dbWEST bash -s <<BASHEOF
export ORACLE_PASSWORD="$GLOBAL_PASS"
\$ORACLE_HOME/bin/sqlplus -s "oggadmin/\$ORACLE_PASSWORD@//localhost:1521/freepdb1" <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 TRIMOUT ON TRIMSPOOL ON
SELECT NVL(
    (SELECT TO_CHAR(MIN(T.START_SCN))
     FROM   gv\$transaction T
     INNER JOIN gv\$session S ON S.SADDR = T.SES_ADDR
     WHERE  T.STATUS = 'ACTIVE'),
    (SELECT TO_CHAR(current_scn) FROM v\$database)
) FROM dual;
EXIT;
SQLEOF
BASHEOF
)

SCN=$(echo "$SCN" | tr -d '[:space:]')

if [[ -z "$SCN" || ! "$SCN" =~ ^[0-9]+$ ]]; then
    print_err "Could not retrieve a valid SCN from source DB. Got: '$SCN'"
    exit 1
fi

print_ok "Captured SCN: $SCN"
echo "$(date): Initial load SCN = $SCN" >> "$LOG_FILE"


# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Create Initial Load Extract (EINIT) on WEST GG
#           source:"tables" = direct table read (non-integrated) — does NOT
#           conflict with EWEST's integrated extract registration on FREEPDB1.
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 8: Create Initial Load Extract ($EXTRACT_INIT) on WEST GG — AS OF SCN $SCN"

get_ogg_port "WEST"

echo "Creating $EXTRACT_INIT on WEST GG..."
api_call "POST" "https://localhost:$ogg_port/services/v2/extracts/$EXTRACT_INIT" \
    '{
        "credentials": {"domain": "OracleGoldenGate", "alias": "WEST"},
        "status": "running",
        "encryptionProfile": "LocalWallet",
        "source": "tables",
        "config": [
            "EXTRACT '"$EXTRACT_INIT"'",
            "USERIDALIAS WEST DOMAIN OracleGoldenGate",
            "EXTFILE '"$TRAIL_INIT"' MEGABYTES '"$TRAIL_INIT_SIZE_MB"' PURGE",
            "TABLEEXCLUDE HR.EMP_DETAILS_VIEW",
            "TABLE HR.*; SQLPREDICATE \"AS OF SCN '"$SCN"'\";"
        ]
    }'

print_ok "$EXTRACT_INIT created and running."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 8b — Create Initial Load Dist Path (DPEI) on WEST GG
#            Forwards trail ei (WEST) → trail di (EAST)
#
#  Design decision: DPEI starts IMMEDIATELY after EINIT, not after EINIT stops.
#  This is intentional — GoldenGate trails are written sequentially, so DPEI
#  can stream trail files to EAST as EINIT writes them.  For large schemas this
#  dramatically reduces the delivery lag: by the time EINIT self-stops, most
#  data is already on EAST and DPEI lag is near zero.
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 8b: Create Initial Load Dist Path ($DISTPATH_INIT) on WEST GG"

get_ogg_port "WEST"

echo "Creating $DISTPATH_INIT (trail $TRAIL_INIT → $TRAIL_INIT_REMOTE on EAST)..."
api_call "POST" "https://localhost:$ogg_port/services/v2/sources/$DISTPATH_INIT" \
    '{
        "name": "'"$DISTPATH_INIT"'",
        "description": "Initial load dist path — '"$TRAIL_INIT"' → '"$TRAIL_INIT_REMOTE"'",
        "source": {"uri": "trail://localhost/services/WEST/distsrvr/v2/sources?trail='"$TRAIL_INIT"'"},
        "target": {
            "uri": "ws://'"$DOCKER_OGG_EAST_IP"':9014/services/v2/targets?trail='"$TRAIL_INIT_REMOTE"'",
            "authenticationMethod": {"domain": "Network", "alias": "oggnet"},
            "details": {
                "trail": {"seqLength": 9, "sizeMB": '"$TRAIL_INIT_SIZE_MB"'},
                "compression": {"enabled": true}
            }
        },
        "begin": {"sequence": 0, "offset": 0},
        "encryptionProfile": "LocalWallet",
        "status": "running"
    }'

print_ok "$DISTPATH_INIT created and running."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 8c — Wait for EINIT to self-stop, then verify DPEI has forwarded
#            everything by comparing DPEI source-read pos to EINIT final pos
# ─────────────────────────────────────────────────────────────────────────────
# DPEI (Step 8b) is already running in parallel with EINIT, streaming trail ei
# to EAST as it is written. We simply wait for EINIT to self-stop, then confirm
# DPEI has drained any remaining lag before proceeding to create RINIT.
print_step "STEP 8c: Wait for $EXTRACT_INIT to self-stop, then confirm $DISTPATH_INIT lag = 0"

get_ogg_port "WEST"

print_ok "Waiting for $EXTRACT_INIT to self-stop (all rows extracted — DPEI streams in parallel)..."
wait_for_stopped "extracts" "$EXTRACT_INIT" "localhost" "$ogg_port"
print_ok "$EXTRACT_INIT completed — trail $TRAIL_INIT fully written."

# DPEI has been running the whole time; lag should be near 0 already
wait_dpei_caught_up


# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Create & start Initial Load Replicat (RINIT) on EAST GG
#           Reads trail di (forwarded by DPEI) and applies to EAST DB
#
#  RINIT is created as an INTEGRATED replicat (parallel:false, type:integrated).
#  Integrated replicats do NOT self-stop at end-of-trail — they wait for more
#  data.  We must therefore poll RINIT's read position and stop it explicitly
#  once it has consumed all records (Step 9b).
#
#  Why integrated?  Integrated replicat uses the DB inbound server for apply,
#  which handles constraint ordering and parallelism automatically — safer for
#  initial load than classic (non-integrated) replicat for this use case.
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 9: Create and start Initial Load Replicat ($REPLICAT_INIT) on EAST GG"

get_ogg_port "EAST"

echo "Creating $REPLICAT_INIT on EAST GG (reads trail $TRAIL_INIT_REMOTE)..."
api_call "POST" "https://localhost:$ogg_port/services/v2/replicats/$REPLICAT_INIT" \
    '{
        "description": "Initial load replicat — reads '"$TRAIL_INIT_REMOTE"', applies to EAST DB",
        "config": [
            "REPLICAT '"$REPLICAT_INIT"'",
            "USERIDALIAS EAST DOMAIN OracleGoldenGate",
            "MAP HR.*, TARGET HR.*;"
        ],
        "credentials": {"alias": "EAST"},
        "mode": {"parallel": false, "type": "integrated"},
        "source": {"name": "'"$TRAIL_INIT_REMOTE"'"},
        "checkpoint": {"table": "'"$CHECKPOINT_TABLE"'"},
        "status": "running"
    }'

print_ok "$REPLICAT_INIT created and running."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 9b — Poll RINIT read position until it reaches DPEI's target-write pos
#            RINIT is an integrated replicat and will NOT self-stop.
#            Explicitly stop it once all initial load records are confirmed applied.
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 9b: Verify $REPLICAT_INIT has applied all initial load records"

get_ogg_port "EAST"

wait_rinit_caught_up

echo "Stopping $REPLICAT_INIT (all initial load records applied)..."
curl -s -o /dev/null -k -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -u "$OGG_USER:$GLOBAL_PASS" \
    -d '{"command":"STOP","isReported":false}' \
    "https://localhost:$ogg_port/services/v2/replicats/$REPLICAT_INIT/command"
sleep 10
print_ok "$REPLICAT_INIT stopped — initial data is fully loaded into EAST DB."

# Stop DPEI — trail fully forwarded (lag=0 confirmed in Step 8c) and RINIT done
get_ogg_port "WEST"
echo "Stopping $DISTPATH_INIT (trail fully forwarded and applied)..."
curl -s -o /dev/null -k -X PATCH \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -u "$OGG_USER:$GLOBAL_PASS" \
    -d '{"status":"stopped"}' \
    "https://localhost:$ogg_port/services/v2/sources/$DISTPATH_INIT"
sleep 3
print_ok "$DISTPATH_INIT stopped."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 9c — Re-enable FK constraints on target DB
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 9c: Re-enable FK constraints on TARGET (EAST) DB"

run_sql_as_sysdba "dbEAST" "FREEPDB1" \
    "
BEGIN
  FOR c IN (
    SELECT c.constraint_name, c.table_name
    FROM   all_constraints c
    WHERE  c.owner = 'HR'
    AND    c.constraint_type = 'R'
    AND    c.status = 'DISABLED'
    ORDER BY c.table_name
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE HR.' || c.table_name
                     || ' ENABLE CONSTRAINT ' || c.constraint_name;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = -26990 THEN NULL;  -- skip CDC tombstone tables
        ELSE RAISE;
        END IF;
    END;
  END LOOP;
END;
/
"

print_ok "FK constraints re-enabled on EAST DB."


# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Start RWEST at captured SCN via commands/execute
#            RWEST has been stopped since Step 6; dw trail accumulated since Step 5b.
#            commands/execute positions the replicat AT the snapshot SCN so CDC
#            changes predating the initial load are skipped (avoids ORA-00001).
# ─────────────────────────────────────────────────────────────────────────────
print_step "STEP 10: Start change Replicat (RWEST) at SCN $SCN"

for replicat in "${replicat_properties[@]}"; do
    IFS=':' read -r region_name replicat_name ogg_ip replicat_file <<< "$replicat"
    get_ogg_port "$region_name"

    print_ok "Starting $replicat_name at SCN $SCN via commands/execute..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/commands/execute" \
        "{
            \"\$schema\": \"ogg:command\",
            \"name\": \"start\",
            \"processType\": \"replicat\",
            \"processName\": \"$replicat_name\",
            \"at\": $SCN,
            \"filterDuplicates\": true
        }"

    # Poll until running (or abended)
    local_w=0
    while [[ $local_w -lt 60 ]]; do
        sleep 3; local_w=$((local_w + 3))
        FINAL_STATUS=$(get_process_status "replicats" "$replicat_name" "$ogg_ip" "$ogg_port")
        FINAL_UP=$(echo "$FINAL_STATUS" | tr '[:lower:]' '[:upper:]')
        print_ok "$replicat_name status: $FINAL_STATUS"
        [[ "$FINAL_UP" == "RUNNING" ]] && break
        [[ "$FINAL_UP" == "ABENDED" ]] && print_err "$replicat_name ABENDED after start." && exit 1
    done
    if [[ "$FINAL_UP" != "RUNNING" ]]; then
        print_err "$replicat_name did not reach RUNNING state within 60s."
        exit 1
    fi
    print_ok "$replicat_name is RUNNING."
done


# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
end_time=$(date +%s)
elapsed=$((end_time - start_time))

get_ogg_port "WEST"; west_port=$ogg_port
get_ogg_port "EAST"; east_port=$ogg_port

status_ewest=$(get_process_status "extracts"  "EWEST" "localhost" "$west_port")
status_dpwe=$(get_process_status  "sources"   "DPWE"  "localhost" "$west_port")
status_rwest=$(get_process_status "replicats" "RWEST" "localhost" "$east_port")
status_einit=$(get_process_status "extracts"  "$EXTRACT_INIT" "localhost" "$west_port")
status_dpei=$(get_process_status  "sources"   "$DISTPATH_INIT" "localhost" "$west_port")
status_rinit=$(get_process_status "replicats" "$REPLICAT_INIT" "localhost" "$east_port")

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✔  Initial Load completed in ${elapsed}s"
echo "════════════════════════════════════════════════════════════"
echo "  Change Extract   : EWEST  ($status_ewest — trail ew)"
echo "  Change Dist Path : DPWE   ($status_dpwe — ew → dw)"
echo "  Change Replicat  : RWEST  ($status_rwest — started at SCN $SCN)"
echo "  Init Extract     : $EXTRACT_INIT  ($status_einit)"
echo "  Init Dist Path   : $DISTPATH_INIT   ($status_dpei)"
echo "  Init Replicat    : $REPLICAT_INIT  ($status_rinit)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  GG WEST WebUI : https://localhost:9090"
echo "  GG EAST WebUI : https://localhost:8080"
echo ""
