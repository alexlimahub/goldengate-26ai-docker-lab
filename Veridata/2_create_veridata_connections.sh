#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Creates two Veridata connections via REST API:
#   WEST -> Agent 1 (port 6826, DB 172.52.0.103)
#   EAST -> Agent 2 (port 6827, DB 172.52.0.104)

VERIDATA_HOST="localhost"
VERIDATA_PORT="8831"
VERIDATA_USER="veridata"
VERIDATA_PASS='Welcome##123'
DB_USER="HR"
DB_PASS='Welcome##123'
AGENT_HOST="oggvdt"
BASE_URL="https://${VERIDATA_HOST}:${VERIDATA_PORT}/veridata/v1"

# Step 1: Login and get JWT token
echo "==> Logging in to Veridata on ${VERIDATA_HOST}:${VERIDATA_PORT}..."
TOKEN=$(curl -sk -u "${VERIDATA_USER}:${VERIDATA_PASS}" \
  "${BASE_URL}/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "❌ Login failed — could not retrieve token. Exiting."
  exit 1
fi
echo "✅ Login successful."
echo ""

# Step 2: Create a connection using the JWT token
create_connection() {
  local conn_name=$1
  local agent_port=$2

  echo "--- Creating connection: ${conn_name} (agent port ${agent_port}) ---"

  RESPONSE=$(curl -sk -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${BASE_URL}/services/configuration/connections" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":        \"${conn_name}\",
      \"description\": \"Veridata connection ${conn_name}\",
      \"host\":        \"${AGENT_HOST}\",
      \"port\":        ${agent_port},
      \"dbType\":      \"ORACLE\",
      \"ssl\":         false,
      \"username\":    \"${DB_USER}\",
      \"password\":    \"${DB_PASS}\"
    }")

  BODY=$(echo "$RESPONSE" | grep -v "HTTP_STATUS:")
  STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)

  if [ "$STATUS" = "201" ]; then
    echo "  ✅ Created successfully (HTTP 201)"
    echo "  Response: $BODY"
  else
    echo "  ❌ Failed (HTTP $STATUS)"
    echo "  Response: $BODY"
  fi
  echo ""
}

echo "==> Creating connections..."
echo ""
create_connection "WEST" 6826
create_connection "EAST" 6827

echo "==> Done."
