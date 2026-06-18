#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Author  : Alex Lima, GoldenGate Product Manager
# Created : 2026-03-17
# ─────────────────────────────────────────────────────────────────────────────
# Checks the status of both Veridata agents inside the oggvdt container.

CONTAINER="oggvdt"

docker exec "$CONTAINER" bash -c '
  check_agent() {
    local label=$1
    local port=$2
    local log=$3
    echo "--- '"'"'$label'"'"' ---"
    PID=$(ss -tlnp 2>/dev/null | grep ":$port" | grep -o "pid=[0-9]*" | cut -d= -f2)
    if [ -n "$PID" ]; then
      echo "  Status : UP"
      echo "  PID    : $PID"
      echo "  Port   : $port"
    else
      echo "  Status : DOWN"
      echo "  Port   : $port"
    fi
    if [ -f "$log" ]; then
      echo "  Last log lines:"
      tail -5 "$log" | sed "s/^/    /"
    fi
    echo ""
  }

  check_agent "Agent 1 - vdt_agent_deployment"   6826 /u01/vdt_agent_deployment/agent.log
  check_agent "Agent 2 - vdt_agent_deployment_2" 6827 /u01/vdt_agent_deployment_2/agent.log
'
