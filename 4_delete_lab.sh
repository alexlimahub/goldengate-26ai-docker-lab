#!/bin/bash
# =============================================================================
#  4_delete_lab.sh
#
#  Author:  Alex Lima - GoldenGate Product Manager
#  Tears down the full lab stack and removes all named volumes.
#
#  Usage:
#    ./4_delete_lab.sh          # delete containers + volumes (full reset)
#    ./4_delete_lab.sh --soft   # stop containers only, keep volumes (faster restart)
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="full"
if [[ "${1}" == "--soft" ]]; then
    MODE="soft"
fi

echo
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}  Oracle GoldenGate Lab — Delete${NC}"
echo -e "${BLUE}${BOLD}  $(date)${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo

if [[ "${MODE}" == "soft" ]]; then
    echo -e "${YELLOW}  Mode: soft — stopping containers, keeping volumes${NC}"
    echo
    (cd "${SCRIPT_DIR}" && docker compose down)
else
    echo -e "${YELLOW}  Mode: full — deleting containers and all volumes${NC}"
    echo -e "${YELLOW}  Veridata state, GoldenGate trails, and DB data will be deleted.${NC}"
    echo
    (cd "${SCRIPT_DIR}" && docker compose down -v)
fi

echo
echo -e "${GREEN}${BOLD}  Lab deleted. Run ./0_start_lab.sh to rebuild from scratch.${NC}"
echo
