#!/bin/bash
# Checks the status of both Veridata agents inside the oggvdt container.
# Author: Alex Lima, GoldenGate Product Manager

CONTAINER="oggvdt"

INNER=$(cat << 'INNEREOF'
check_agent() {
  local label=$1
  local port=$2
  local deploy_dir=$3
  echo "--- '$label' ---"

  PID=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -o "pid=[0-9]*" | cut -d= -f2)

  if [ -n "$PID" ]; then
    echo "  Status : UP"
    echo "  PID    : $PID"
    echo "  Port   : $port"
  else
    echo "  Status : DOWN"
    echo "  Port   : $port"
  fi

  LOG="$deploy_dir/logs/veridata-agent.log"
  # if [ -f "$LOG" ]; then
  #   echo "  Last log lines:"
  #   tail -3 "$LOG" | sed "s/^/    /"
  # fi
  echo ""
}

check_agent "Agent 1 - vdt_agent_deployment"   6826 /u01/vdt_agent_deployment
sleep 3
check_agent "Agent 2 - vdt_agent_deployment_2" 6827 /u01/vdt_agent_deployment_2
INNEREOF
)

echo "$INNER" | docker exec -i "$CONTAINER" bash
