#!/bin/bash

# This script will peforme the following steps:
# 1. Create database connection in the source (WEST) and target (EAST)
# 2. Create Distribution Path user on both source and target (For this exapmle we only needed in the target, but for simplicity it's created on both)
# 3. Create a Path connection on both
# 4. 

start_time=$(date +%s)

# Wait for all GoldenGate stack endpoints before proceeding
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/0_wait_for_stack.sh"

# Load variables from the environment file
source .env

# IPs
# DOCKER_OGG_WEST_IP=172.51.0.101
# DOCKER_OGG_EAST_IP=172.51.0.102
# DOCKER_DB_WEST_IP=172.51.0.103
# DOCKER_DB_EAST_IP=172.51.0.104
# OGG_ADMIN_PWD=<password> 

# Global variables
GLOBAL_PASS=$OGG_ADMIN_PWD
LOG_FILE="goldengate_setup.log"
OGG_USER="oggadmin"

# Define connection properties for WEST and EAST regions
conn_properties=("WEST:$DOCKER_DB_WEST_IP:localhost" "EAST:$DOCKER_DB_EAST_IP:localhost")

# Define process configurations (Extracts, Distribution Paths, Replicats)
extract_properties=("WEST:EWEST:ew:localhost")
distpath_properties=("WEST:DPWE:ew:localhost:$DOCKER_OGG_EAST_IP:dw")
replicat_properties=("EAST:RWEST:localhost:dw")

# Define trail purge properties for cleanup
trail_purge_properties=("WEST:ew:localhost" "EAST:dw:localhost")

# Function to set GoldenGate ports dynamically based on region
get_ogg_port() {
    case $1 in
        "WEST") ogg_port="9090"; ogg_port_deployment="9091" ;;
        "EAST") ogg_port="8080"; ogg_port_deployment="8081" ;;
        *) echo "Invalid region: $1"; exit 1 ;;
    esac
}

# Function to handle API calls with error handling and JSON formatting
api_call() {
    local method=$1
    local url=$2
    local data=$3

    # Execute API call and capture response
    response=$(curl -s -o response.json -w "%{http_code}" -k -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -u "$OGG_USER:$GLOBAL_PASS" \
        -d "$data")

    # If API call fails, log error and exit
    http_status=$(tail -n1 <<< "$response")  # Extract last line (HTTP code)
    json_response=$(cat response.json)       # Capture response body

    if [[ "$http_status" -ne 200 && "$http_status" -ne 201 ]]; then
        echo "Error: API call failed for $url (HTTP $http_status). Response:" | tee -a "$LOG_FILE"
        echo "$json_response" | tee -a "$LOG_FILE"
      #  exit 1
    else
        echo "$json_response" | jq '.'  # Display formatted JSON response
    fi
}

# Create database connections and managed process profiles
for region in "${conn_properties[@]}"; do
    IFS=':' read -r conn_name db_ip ogg_ip <<< "$region"
    get_ogg_port "$conn_name"

    echo "Creating credentials for $conn_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/credentials/OracleGoldenGate/$conn_name" \
        '{"userid":"oggadmin@'$db_ip':1521/freepdb1","password":"'$GLOBAL_PASS'"}'
   

    echo "Creating GoldenGate user for Distribution Path..."
    api_call "POST" "http://$ogg_ip:$ogg_port_deployment/services/v2/authorizations/Operator/oggnet" \
        '{"credential":"'$GLOBAL_PASS'","info":"Distribution Path User"}'

    echo "Creating Network Alias for Distribution Path..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/credentials/Network/oggnet" \
        '{"userid":"oggnet","password":"'$GLOBAL_PASS'"}'

    ## A) Create a managed process profile for each region
    echo "Creating Custom Profile '$conn_name-profile'..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/$conn_name/adminsrvr/v2/config/types/ogg:managedProcessSettings/values/ogg:managedProcessSettings:$conn_name-profile" \
        '{
            "autoStart": {"enabled": true, "delay": 60},
            "autoRestart": {"enabled": true, "retries": 9, "delay": 60, "window": 3600, "onSuccess": false, "disableOnFailure": true}
        }'

    echo "Setting Custom Profile '$conn_name-profile' as Default..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/$conn_name/adminsrvr/v2/config/types/ogg:configDataDescription/values/ogg:managedProcessSettings:$conn_name-profile" \
        '{
            "$schema": "ogg:configDataDescription",
            "description": "'$conn_name' Profile",
            "isDefault": true
        }'

    ## B) Add SchemaTrandata, Heartbeat, and Checkpoint Tables
    echo "Adding SchemaTrandata for $conn_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/connections/OracleGoldenGate.$conn_name/trandata/schema" \
        '{"operation":"add","schemaName":"hr","allColumns":true}'

    echo "Adding Heartbeat Table for $conn_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/connections/OracleGoldenGate.$conn_name/tables/heartbeat" \
        '{"frequency":60}'

    echo "Adding Checkpoint Table for $conn_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/connections/OracleGoldenGate.$conn_name/tables/checkpoint" \
        '{"operation":"add","name":"oggadmin.checkpoints"}'

    # ## C) Create Masterkey for encryption
    if [ "$conn_name" == "WEST" ]; then
    echo "Adding MASTERKEY for $conn_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/masterkey"
    fi
done

# Create Extracts
for extract in "${extract_properties[@]}"; do
    IFS=':' read -r region_name extract_name extract_file ogg_ip <<< "$extract"
    get_ogg_port "$region_name"

    echo "Creating Extract $extract_name on $region_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/extracts/$extract_name" \
        '{
            "description":"Extract Demo",
            "config":["EXTRACT '$extract_name'","ENCRYPTTRAIL AES256","EXTTRAIL '$extract_file'","USERIDALIAS '$region_name' DOMAIN OracleGoldenGate","TRANLOGOPTIONS EXCLUDETAG 00","DDL INCLUDE MAPPED","TABLE HR.*;"],
            "source":"tranlogs",
            "credentials":{"alias":"'$region_name'"},
            "registration":"default",
            "begin":"now",
            "targets":[{"name":"'$extract_file'","sizeMB":1}],
            "critical": false,
            "managedProcessSettings":"'$region_name'-profile",
            "encryptionProfile":"LocalWallet",
            "status":"running"
        }'
done
#            "encryptionProfile":"LocalWallet",

# Create Distribution Paths
for dp in "${distpath_properties[@]}"; do
    IFS=':' read -r region_name dp_name extract_file ogg_ip ogg_ip_remote dp_filename <<< "$dp"
    get_ogg_port "$region_name"

    echo "Creating Distribution Path $dp_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/sources/$dp_name" \
        '{
            "name":"'$dp_name'",
            "description":"DIST PATH '$dp_name'",
            "source":{"uri":"trail://'$ogg_ip'/services/'$region_name'/distsrvr/v2/sources?trail='$extract_file'"},
            "target":{"uri":"ws://'$ogg_ip_remote':9014/services/v2/targets?trail='$dp_filename'","authenticationMethod":{"domain":"Network","alias":"oggnet"},
            "details":{"trail": {"seqLength": 9,"sizeMB": 1},"compression": {"enabled": true}}},
            "begin":{"sequence":0,"offset":0},
            "encryptionProfile":"LocalWallet",
            "status":"running"
        }'
done

# "encryption": {"algorithm": "AES256"}  #Cannot encrypt a trail file twice.

# Copy Wallet from source to target (docker commnad in this automation)
docker cp oggWEST:/u02/Deployment/var/lib/wallet/cwallet.sso .
docker cp ./cwallet.sso oggEAST:/u02/Deployment/var/lib/wallet/cwallet.sso
#docker exec oggEAST chown ogg:ogg /u02/Deployment/var/lib/wallet/cwallet.sso
#docker exec -u 0 oggEAST chown ogg:ogg /u02/Deployment/var/lib/wallet/cwallet.sso
docker exec -u 0 oggEAST chown 1001:root /u02/Deployment/var/lib/wallet/cwallet.sso

#docker exec ogg238E chmod 744 /u02/Deployment/var/lib/wallet/cwallet.sso

# Create Replicats
for replicat in "${replicat_properties[@]}"; do
    IFS=':' read -r region_name replicat_name ogg_ip replicat_file <<< "$replicat"
    get_ogg_port "$region_name"

    echo "Creating Replicat $replicat_name..."
    api_call "POST" "https://$ogg_ip:$ogg_port/services/v2/replicats/$replicat_name" \
        '{
            "description":"Replicat Demo",
            "config":["REPLICAT '$replicat_name'","USERIDALIAS '$region_name' DOMAIN OracleGoldenGate","DDL INCLUDE MAPPED","MAP hr.*, TARGET hr.*;"],
            "credentials":{"alias":"'$region_name'"},
            "mode":{"parallel":true,"type":"nonintegrated"},
            "source":{"name":"'$replicat_file'"},
            "checkpoint":{"table":"oggadmin.checkpoints"},
            "managedProcessSettings":"'$region_name'-profile",
            "status":"running"
        }'
done


end_time=$(date +%s)
elapsed=$(( end_time - start_time ))

echo
echo "Execution time: $elapsed seconds"
echo "GoldenGate setup completed successfully!"

bash "${SCRIPT_DIR}/2_generate_load.sh" --west --create