#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  0_wait_for_stack.sh
#
#  Author  : Alex Lima, GoldenGate Product Manager
#  Waits for all GoldenGate stack endpoints to become available
#  and reports how long each took.
#
#  Fixes vs original:
#    • Elapsed time in wait messages uses wall-clock (date +%s - START), not an
#      iteration counter — so the seconds shown are always accurate even when
#      curl takes several seconds to time out on an unreachable service.
#    • curl gets --connect-timeout 5 --max-time 10 so slow/hung services don't
#      stall a check iteration for minutes.
#    • Waiting messages now show the last HTTP code received, making it obvious
#      whether a service is unreachable (000) or just returning an unexpected
#      code (e.g. 401, 404, 503).
#    • Per-endpoint accepted-code list: GG ports need 200; Veridata accepts any
#      HTTP response (2xx/3xx/4xx) — once the web server answers at all, the
#      service is up enough for the lab to proceed.
#    • Poll interval 5 s instead of 1 s (reduces noise; curl timeout means 1 s
#      intervals were never really 1 s anyway).
#    • Overall timeout (default 600 s) with a clear error if any service never
#      comes up, rather than hanging forever.
# ─────────────────────────────────────────────────────────────────────────────

START=$(date +%s)
MAX_WAIT=${STACK_WAIT_TIMEOUT:-600}   # seconds; override via environment
POLL=5                                # seconds between probes

# ── check_endpoint <label> <url> <accepted-codes...> ─────────────────────────
#   Probes <url> every POLL seconds until it returns one of <accepted-codes>.
#   Uses actual wall-clock elapsed time for all messages.
#   Any HTTP response code other than 000 (no connection) is shown in messages.
# ─────────────────────────────────────────────────────────────────────────────
check_endpoint() {
    local label="$1"
    local url="$2"
    shift 2
    local accepted=("$@")   # remaining args are acceptable HTTP codes

    local last_code=""

    while true; do
        local elapsed=$(( $(date +%s) - START ))

        # Bail out if we've waited too long
        if (( elapsed >= MAX_WAIT )); then
            echo "  ❌ $label TIMEOUT after ${elapsed}s (last HTTP: ${last_code:-none})"
            return 1
        fi

        local code
        code=$(curl -sk \
                    --connect-timeout 5 \
                    --max-time 10 \
                    "$url" \
                    -o /dev/null \
                    -w '%{http_code}' 2>/dev/null)

        elapsed=$(( $(date +%s) - START ))   # refresh after curl finishes

        # Check if this code is in the accepted list
        local ok=false
        for ac in "${accepted[@]}"; do
            [[ "$code" == "$ac" ]] && ok=true && break
        done

        if $ok; then
            echo "  ✅ $label → HTTP $code (${elapsed}s)"
            return 0
        fi

        last_code="$code"
        echo "  ⏳ $label still waiting... (${elapsed}s, HTTP: ${code:-000})"
        sleep "$POLL"
    done
}

echo ""
echo "=== Waiting for GoldenGate Stack ==="
echo "    Started at : $(date)"
echo "    Timeout    : ${MAX_WAIT}s"
echo ""

# GG ports — 200 or 302 (redirect to login means fully initialised)
check_endpoint "GG WEST  (9090)" "https://localhost:9090" 200 301 302 &
check_endpoint "GG EAST  (8080)" "https://localhost:8080" 200 301 302 &
check_endpoint "GG WEST  (9091)" "http://localhost:9091"  200 301 302 &
check_endpoint "GG EAST  (8081)" "http://localhost:8081"  200 301 302 &

# Veridata — uses HTTPS; 301 redirect to login = fully up.
check_endpoint "Veridata (8831)" "https://localhost:8831/veridata" \
    200 201 301 302 400 401 403 404 &

wait
rc=$?

TOTAL=$(( $(date +%s) - START ))

echo ""
if [[ $rc -eq 0 ]]; then
    echo "=== All services up! Total wait: ${TOTAL}s ==="
else
    echo "=== WARNING: one or more services timed out after ${TOTAL}s ==="
    echo "    Check the output above for details."
fi
echo ""
