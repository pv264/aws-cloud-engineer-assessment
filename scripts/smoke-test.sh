#!/usr/bin/env bash
# Post-deploy smoke test.  Usage: scripts/smoke-test.sh <base-url>
# SMOKE_READ_ONLY=true skips the write checks (used for production).
set -euo pipefail

BASE_URL="${1:?usage: $0 <base-url>}"
BASE_URL="${BASE_URL%/}"
READ_ONLY="${SMOKE_READ_ONLY:-false}"
CURL=(curl --silent --show-error --max-time 10 --retry 5 --retry-delay 3 --retry-all-errors)

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
status_of() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@"; }

echo "Smoke testing ${BASE_URL} (read-only=${READ_ONLY})"

[ "$(status_of "${BASE_URL}/health")" = "200" ] || fail "/health is not 200"
[ "$(status_of "${BASE_URL}/health/ready")" = "200" ] || fail "/health/ready is not 200 (database unreachable?)"
[ "$(status_of "${BASE_URL}/orders/00000000-0000-0000-0000-000000000000")" = "404" ] || fail "unknown order is not 404"

if [ "$READ_ONLY" != "true" ]; then
  key="smoke-$(date +%s)-$RANDOM"
  body='{"customer_id":"smoke-test","currency":"USD","items":[{"sku":"SMOKE-1","quantity":2,"unit_price":"1.50"}]}'
  post() {
    "${CURL[@]}" -o /tmp/smoke-body.json -w '%{http_code}' -X POST "${BASE_URL}/orders" \
      -H 'Content-Type: application/json' -H "Idempotency-Key: ${key}" -d "$body"
  }

  [ "$(post)" = "201" ] || fail "POST /orders did not return 201"
  order_id=$(python3 -c 'import json; print(json.load(open("/tmp/smoke-body.json"))["id"])')
  [ "$(post)" = "200" ] || fail "idempotent replay did not return 200"
  replay_id=$(python3 -c 'import json; print(json.load(open("/tmp/smoke-body.json"))["id"])')
  [ "$order_id" = "$replay_id" ] || fail "idempotent replay returned a different order"
  [ "$(status_of "${BASE_URL}/orders/${order_id}")" = "200" ] || fail "GET /orders/{id} did not return 200"
fi

echo "Smoke test passed"
