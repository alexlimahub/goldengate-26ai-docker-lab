#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Creates a second Veridata agent deployment inside the oggvdt container.
# Run this script from outside the container.

CONTAINER="oggvdt"
AGENT_INSTALL_DIR="/u01/vdt/agent"
AGENT_SRC_DEPLOYMENT="/u01/vdt_agent_deployment"
AGENT_NEW_DEPLOYMENT="/u01/vdt_agent_deployment_2"

echo "==> Creating new Veridata agent deployment in container: $CONTAINER"

# Step 0: Cleanup — run as separate exec to avoid pkill self-matching the main script
echo "--- Step 0: Cleanup existing deployment (if any) ---"
echo "Checking for process on port 6827..."
PID=$(docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep ":6827 " | grep -o "pid=[0-9]*" | cut -d= -f2)
if [ -n "$PID" ]; then
  echo "Killing PID $PID on port 6827..."
  docker exec "$CONTAINER" kill -9 "$PID"
  sleep 3
else
  echo "No process found on port 6827."
fi

if docker exec "$CONTAINER" test -d "$AGENT_NEW_DEPLOYMENT"; then
  echo "Removing $AGENT_NEW_DEPLOYMENT..."
  docker exec "$CONTAINER" rm -rf "$AGENT_NEW_DEPLOYMENT"
  echo "Cleanup done."
else
  echo "No existing deployment found, skipping cleanup."
fi

# Steps 1-7: Create, configure, and start the new agent
docker exec "$CONTAINER" bash -c "
  set -e
  export JAVA_HOME=/usr

  echo '--- Step 1: Running agent_config.sh to create $AGENT_NEW_DEPLOYMENT ---'
  cd $AGENT_INSTALL_DIR
  ./agent_config.sh $AGENT_NEW_DEPLOYMENT

  echo '--- Step 2: Copying agent.properties from first deployment ---'
  mkdir -p $AGENT_NEW_DEPLOYMENT
  cd $AGENT_NEW_DEPLOYMENT
  cp $AGENT_SRC_DEPLOYMENT/agent.properties agent.properties

  echo '--- Step 3: Updating server.port to 6827 ---'
  sed -i 's|^server\.port=.*|server.port=6827|' agent.properties

  echo '--- Step 4: Updating database.url ---'
  sed -i 's|^database\.url=jdbc:oracle:thin:@172\.52\.0\.103:1521/freepdb1|database.url=jdbc:oracle:thin:@172.52.0.104:1521/freepdb1|' agent.properties

  echo '--- Step 5: Ensuring server.driversLocation is set ---'
  if grep -q '^server\.driversLocation=' agent.properties; then
    sed -i 's|^server\.driversLocation=.*|server.driversLocation=/u01/vdt/agent/drivers|' agent.properties
  else
    echo 'server.driversLocation=/u01/vdt/agent/drivers' >> agent.properties
  fi

  echo '--- Step 6: Appending server.jdbcDriver (if not already present) ---'
  if ! grep -q '^server\.jdbcDriver=ojdbc11-23\.9\.0\.25\.07\.jar' agent.properties; then
    echo 'server.jdbcDriver=ojdbc11-23.9.0.25.07.jar' >> agent.properties
  fi

  echo '--- Done. Final agent.properties: ---'
  cat agent.properties

  echo '--- Step 7: Starting Veridata agent in background ---'
  nohup $AGENT_NEW_DEPLOYMENT/agent.sh run > $AGENT_NEW_DEPLOYMENT/agent.log 2>&1 &
  echo \"Agent started with PID \$!\"
"

echo "==> Script completed."
