#!/usr/bin/env bash
# status.sh — health/config check for the Prospector Studio local stack.
#
# Walks the stack layer by layer (config -> containers -> datastores ->
# identity -> app -> LLM -> telemetry) and reports PASS / WARN / FAIL for each
# check, so a failure is localised to a layer instead of "the browser is white".
#
#   ./status.sh
#
# Exit code: 0 if no FAILs, 1 otherwise. WARNs never fail the run (they flag
# things that are known-degraded-on-purpose, e.g. embeddings left unconfigured).
set -uo pipefail
cd "$(dirname "$0")"

# ── output helpers ────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'
else
  G=""; Y=""; R=""; B=""; D=""; X=""
fi
PASS=0; WARN=0; FAILN=0
pass() { printf '  %s✓%s %s\n'      "$G" "$X" "$1"; PASS=$((PASS+1)); }
warn() { printf '  %s●%s %s\n'      "$Y" "$X" "$1"; WARN=$((WARN+1)); [[ -n "${2:-}" ]] && printf '      %s%s%s\n' "$D" "$2" "$X"; }
fail() { printf '  %s✗%s %s\n'      "$R" "$X" "$1"; FAILN=$((FAILN+1)); [[ -n "${2:-}" ]] && printf '      %s%s%s\n' "$D" "$2" "$X"; }
info() { printf '  %s·%s %s\n'      "$D" "$X" "$1"; }
sect() { printf '\n%s%s%s\n' "$B" "$1" "$X"; }

PROJECT="studio-stack"          # pinned via `name:` in docker-compose.yml
NET="${STATUS_NET:-$PROJECT}"
CURL_IMG="curlimages/curl:latest"

# ── 0. prerequisites ──────────────────────────────────────────────────────
sect "Prerequisites"
command -v docker >/dev/null 2>&1 && pass "docker present" || { fail "docker not found on PATH"; exit 1; }
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || { HAVE_JQ=0; info "jq not found — some LLM-model detail checks will be skipped"; }
if [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
  fail "stack is not running" "bring it up with: docker compose up -d"
  printf '\n%sSummary:%s %s0 pass%s, %s0 warn%s, %s1 fail%s\n' "$B" "$X" "$G" "$X" "$Y" "$X" "$R" "$X"
  exit 1
fi
pass "compose stack is up"

# ── 1. config files & .env ────────────────────────────────────────────────
sect "Configuration"
if [[ -f .env ]]; then
  pass ".env present"
  set -a; . ./.env 2>/dev/null; set +a
else
  fail ".env missing" "run ./setup.sh"
fi
DOMAIN="${DOMAIN:-strike48.local}"; PORT="${CADDY_HTTP_PORT:-8888}"

req_var() { # name -> FAIL if empty
  local v="${!1:-}"
  [[ -n "$v" ]] && pass "$1 set" || fail "$1 is empty in .env"
}
for v in SECRET_KEY_BASE MATRIX_ORG_AUDIT_HMAC_KEY LLM_BASE_URL LLM_API_KEY LLM_CHAT_MODEL LLM_EMBED_MODEL LLM_CONTEXT_LIMIT; do
  req_var "$v"
done
# schema-drift / footgun checks
case "${LLM_BASE_URL:-}" in
  *your-openai-compatible-endpoint*) fail "LLM_BASE_URL is still the template placeholder" "point it at a real OpenAI-compatible endpoint, then ./setup.sh" ;;
esac
[[ "${LLM_CHAT_MODEL:-}" == "your-chat-model-id" ]] && warn "LLM_CHAT_MODEL is still the placeholder id"
if [[ -n "${LLM_CHAT_MODEL:-}" && "${LLM_CHAT_MODEL:-}" == "${LLM_EMBED_MODEL:-}" ]]; then
  fail "LLM_CHAT_MODEL == LLM_EMBED_MODEL" "identical ids collide as duplicate [models.\"...\"] keys — Alpaca won't parse config.toml"
else
  pass "chat/embed model ids differ (no TOML key collision)"
fi
if [[ -n "${LLM_CONTEXT_LIMIT:-}" ]]; then
  info "LLM_CONTEXT_LIMIT=$LLM_CONTEXT_LIMIT -> Studio will request ~$((LLM_CONTEXT_LIMIT/4)) completion tokens (must stay under the server's real output cap)"
fi
# generated files
for f in caddy/tls/cert.pem keycloak/tls/cert.pem keycloak/realms/non-prod-realm.json studio-overrides/runtime.exs alpaca/config.toml; do
  [[ -f "$f" ]] && pass "generated: $f" || fail "missing: $f" "run ./setup.sh"
done
# rendered config has no unresolved tokens
if [[ -f alpaca/config.toml ]]; then
  if grep -q '@@LLM' alpaca/config.toml; then
    fail "alpaca/config.toml has unresolved @@LLM…@@ tokens" "re-run ./setup.sh (it needs the LLM_* vars set)"
  else
    pass "alpaca/config.toml fully rendered"
  fi
fi
# /etc/hosts (needed for browser login; edge checks below use --resolve regardless)
if grep -qE "studio\.${DOMAIN}" /etc/hosts && grep -qE "auth\.${DOMAIN}" /etc/hosts; then
  pass "/etc/hosts has studio.$DOMAIN + auth.$DOMAIN"
else
  warn "/etc/hosts missing studio.$DOMAIN / auth.$DOMAIN" "browser login needs: 127.0.0.1 auth.$DOMAIN studio.$DOMAIN"
fi

# ── 2. containers ─────────────────────────────────────────────────────────
sect "Containers"
LONG="caddy postgres keycloak studio alpaca construct rustfs victoria-metrics victoria-logs victoria-traces otel-collector"
ONESHOT="createbuckets feature-flags"
check_container() { # svc  kind(long|oneshot)
  local svc="$1" kind="$2" cid="${PROJECT}-$1-1"
  local raw; raw=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.ExitCode}}' "$cid" 2>/dev/null)
  if [[ -z "$raw" ]]; then fail "$svc: container not found ($cid)"; return; fi
  local st rest health ec
  st="${raw%%|*}"; rest="${raw#*|}"; health="${rest%%|*}"; ec="${rest##*|}"
  if [[ "$kind" == oneshot ]]; then
    case "$st" in
      exited) [[ "$ec" == 0 ]] && pass "$svc: completed (exit 0)" || fail "$svc: exited $ec" "docker compose logs $svc" ;;
      running) warn "$svc: still running (one-shot)" ;;
      *) fail "$svc: $st" ;;
    esac
    return
  fi
  if [[ "$st" != running ]]; then fail "$svc: $st" "docker compose logs $svc"; return; fi
  case "$health" in
    healthy)  pass "$svc: running (healthy)" ;;
    starting) warn "$svc: running (health: starting)" ;;
    "-"|"")   pass "$svc: running" ;;
    *)        fail "$svc: running but health=$health" "docker compose logs $svc" ;;
  esac
}
for s in $LONG;    do check_container "$s" long;    done
for s in $ONESHOT; do check_container "$s" oneshot; done

# ── internal network probe (one throwaway curl container) ─────────────────
# Alpaca/keycloak/etc aren't published to the host, so probe from inside the
# compose network. Alpaca's image has no curl, hence the sidecar.
sect "Internal service probes"
info "probing keycloak / alpaca / construct / rustfs / victoria via an in-network curl sidecar…"
PROBE=$(docker run --rm --network "$NET" --entrypoint sh "$CURL_IMG" -c '
  h(){ curl -sS -m "$1" -o /tmp/b -w "%{http_code}" "$2" 2>/dev/null || echo 000; }
  echo "keycloak=$(h 8 http://keycloak:8080/realms/non-prod/.well-known/openid-configuration)"
  echo "alpaca_models=$(curl -sS -m 10 -o /tmp/m -w "%{http_code}" http://alpaca:3000/v1/models 2>/dev/null || echo 000)"
  cc=$(curl -sS -m 60 -o /tmp/c -w "%{http_code}" -X POST http://alpaca:3000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"default\",\"messages\":[{\"role\":\"user\",\"content\":\"say pong\"}],\"max_tokens\":64}" 2>/dev/null || echo 000)
  echo "alpaca_chat=$cc"; grep -q "\"choices\"" /tmp/c && echo "alpaca_chat_ok=1" || echo "alpaca_chat_ok=0"
  ce=$(curl -sS -m 30 -o /tmp/e -w "%{http_code}" -X POST http://alpaca:3000/v1/embeddings -H "Content-Type: application/json" -d "{\"model\":\"embed\",\"input\":\"hi\"}" 2>/dev/null || echo 000)
  echo "alpaca_embed=$ce"; grep -q "\"embedding\"" /tmp/e && echo "alpaca_embed_ok=1" || echo "alpaca_embed_ok=0"
  echo "construct=$(h 8 http://construct:3000/)"
  echo "rustfs=$(h 8 http://rustfs:9000/)"
  echo "vm=$(h 6 http://victoria-metrics:8428/health)"
  echo "vl=$(h 6 http://victoria-logs:9428/health)"
  echo "vt=$(h 6 http://victoria-traces:10428/health)"
' 2>/dev/null)
[[ -z "$PROBE" ]] && warn "internal probe sidecar produced no output" "is '$CURL_IMG' pullable and network '$NET' present?"
pget() { printf '%s\n' "$PROBE" | sed -n "s/^$1=//p" | head -1; }

# ── 3. datastores ─────────────────────────────────────────────────────────
sect "Datastores"
DBS=$(docker compose exec -T postgres psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname IN ('elixir','rag','keycloak')" 2>/dev/null | tr -d ' \r')
for db in elixir rag keycloak; do
  printf '%s\n' "$DBS" | grep -qx "$db" && pass "postgres: db '$db' present" || fail "postgres: db '$db' missing" "expected init.sql to create it"
done
case "$(pget rustfs)" in
  000) fail "rustfs (S3): no response on :9000" "docker compose logs rustfs" ;;
  *)   pass "rustfs (S3): responding on :9000" ;;
esac
CB="${PROJECT}-createbuckets-1"
if [[ "$(docker inspect -f '{{.State.ExitCode}}' "$CB" 2>/dev/null)" == 0 ]]; then
  pass "S3 bucket init: createbuckets completed"
else
  warn "S3 bucket init: createbuckets did not exit cleanly" "docker compose logs createbuckets"
fi

# ── 4. identity (keycloak) ────────────────────────────────────────────────
sect "Identity (Keycloak)"
case "$(pget keycloak)" in
  200) pass "keycloak: realm 'non-prod' issuer reachable (internal :8080)" ;;
  000) fail "keycloak: no response internally" "docker compose logs keycloak" ;;
  *)   fail "keycloak: issuer returned HTTP $(pget keycloak)" "realm import may have failed — docker compose logs keycloak" ;;
esac
WK=$(curl -sk -m 8 --resolve "auth.$DOMAIN:$PORT:127.0.0.1" -o /dev/null -w '%{http_code}' \
     "https://auth.$DOMAIN:$PORT/realms/non-prod/.well-known/openid-configuration" 2>/dev/null)
case "$WK" in
  200) pass "keycloak via Caddy edge (https://auth.$DOMAIN:$PORT): 200" ;;
  000) fail "Caddy edge for auth.$DOMAIN:$PORT unreachable" "docker compose logs caddy" ;;
  *)   fail "auth edge returned HTTP $WK" ;;
esac

# ── 5. app (studio / construct) ───────────────────────────────────────────
sect "Application (Studio)"
SC=$(curl -sk -m 8 --resolve "studio.$DOMAIN:$PORT:127.0.0.1" -o /dev/null -w '%{http_code}' \
     "https://studio.$DOMAIN:$PORT/" 2>/dev/null)
case "$SC" in
  200|302|303|307) pass "studio via Caddy edge: HTTP $SC (login redirect)" ;;
  000) fail "studio edge unreachable" "docker compose logs studio caddy" ;;
  5*)  fail "studio edge returned $SC" "app boot/migration error — docker compose logs studio" ;;
  *)   warn "studio edge returned HTTP $SC" ;;
esac
# runtime.exs override footgun: compose mounts it at /app/releases/<ver>/, which
# must match the image's internal release version (README warns about this — the
# path uses the release's INTERNAL version, not the image tag). The image is
# distroless-ish (has /bin/sh but no ls), and the running container's PATH omits
# /bin, so read the version via an absolute-path shell + glob.
MP=$(docker inspect "${PROJECT}-studio-1" -f '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null | grep -E '/app/releases/.*/runtime\.exs' | head -1)
MOUNTVER=""; [[ -n "$MP" ]] && MOUNTVER=$(printf '%s' "$MP" | sed -E 's#/app/releases/([^/]+)/runtime\.exs#\1#')
ACTVER=$(docker compose exec -T studio /bin/sh -c 'for d in /app/releases/*/; do printf "%s\n" "${d#/app/releases/}"; done' 2>/dev/null | tr -d '/ \r' | head -1)
if [[ -z "$MOUNTVER" ]]; then
  warn "no runtime.exs override mount on the studio container" "the studio-overrides/runtime.exs volume is not mounted — Organization admin may not boot standalone"
elif [[ -z "$ACTVER" ]]; then
  info "runtime.exs override mounted at release $MOUNTVER (couldn't read the image's actual version to cross-check)"
elif [[ "$ACTVER" == "$MOUNTVER" ]]; then
  pass "runtime.exs override mount path matches studio release ($ACTVER)"
else
  warn "studio release is $ACTVER but the override is mounted at /app/releases/$MOUNTVER/runtime.exs" "STUDIO_IMAGE was bumped — update the studio volume path in docker-compose.yml to /app/releases/$ACTVER/runtime.exs"
fi
if grep -q org_admin_dev studio-overrides/runtime.exs 2>/dev/null; then
  pass "runtime.exs override has the org_admin_dev_* settings"
else
  warn "studio-overrides/runtime.exs is missing the org_admin_dev_* marker" "regenerate via ./setup.sh — Organization admin may fail to boot standalone"
fi
case "$(pget construct)" in
  000) warn "construct: no response on :3000" "tool/agent features may not work — docker compose logs construct" ;;
  *)   pass "construct: responding on :3000 (HTTP $(pget construct))" ;;
esac

# ── 6. LLM (Alpaca -> your endpoint) ──────────────────────────────────────
sect "LLM (Alpaca gateway)"
case "$(pget alpaca_models)" in
  200) pass "alpaca: HTTP API up, model list served (:3000)" ;;
  000) fail "alpaca: no response on :3000" "docker compose logs alpaca" ;;
  *)   fail "alpaca: /v1/models returned $(pget alpaca_models)" "check alpaca/config.toml — docker compose logs alpaca" ;;
esac
if [[ "$(pget alpaca_chat_ok)" == 1 ]]; then
  pass "chat path end-to-end: Alpaca -> $LLM_BASE_URL -> $LLM_CHAT_MODEL OK"
else
  fail "chat completion failed (HTTP $(pget alpaca_chat))" "endpoint/key/model wrong, or LLM_CONTEXT_LIMIT too high (upstream 400). Try: curl -H \"Authorization: Bearer \$LLM_API_KEY\" $LLM_BASE_URL/models"
fi
if [[ "$(pget alpaca_embed_ok)" == 1 ]]; then
  pass "embeddings path end-to-end OK (model '$LLM_EMBED_MODEL')"
else
  warn "embeddings not working (HTTP $(pget alpaca_embed)) — RAG/embedding features will error" "no embedding endpoint configured. e.g. pull nomic-embed-text on the gateway's ollama, set LLM_EMBED_MODEL=ollama/nomic-embed-text, ./setup.sh"
fi
# direct reachability of the endpoint from the host (distinguishes gateway-down
# from alpaca-misconfigured)
if [[ -n "${LLM_BASE_URL:-}" ]]; then
  LM=$(curl -sS -m 8 -H "Authorization: Bearer ${LLM_API_KEY:-}" -o /tmp/_lm -w '%{http_code}' "${LLM_BASE_URL%/}/models" 2>/dev/null || echo 000)
  case "$LM" in
    200)
      if [[ "$HAVE_JQ" == 1 ]] && jq -e --arg m "${LLM_CHAT_MODEL:-}" '.data[]?|select(.id==$m)' /tmp/_lm >/dev/null 2>&1; then
        pass "endpoint reachable from host and serves '$LLM_CHAT_MODEL'"
      else
        warn "endpoint reachable but did not advertise '$LLM_CHAT_MODEL' in /models" "the id must match exactly what the server names it"
      fi ;;
    401|403) warn "endpoint reachable but rejected the key (HTTP $LM)" "LLM_API_KEY may be wrong — many gateways need a real bearer even for 'no-auth' models" ;;
    000) info "endpoint not reachable directly from host (may be container-network only) — chat check above is authoritative" ;;
    *)   warn "endpoint /models returned HTTP $LM from host" ;;
  esac
fi

# ── 7. telemetry (informational — container state above is authoritative) ─
sect "Telemetry (informational)"
for kv in "victoria-metrics:vm" "victoria-logs:vl" "victoria-traces:vt"; do
  name="${kv%%:*}"; key="${kv##*:}"
  case "$(pget "$key")" in
    200) info "$name: /health 200" ;;
    000) info "$name: no /health response (may still be ingesting fine)" ;;
    *)   info "$name: /health HTTP $(pget "$key")" ;;
  esac
done

# ── summary ───────────────────────────────────────────────────────────────
printf '\n%sSummary:%s %s%d pass%s, %s%d warn%s, %s%d fail%s\n' \
  "$B" "$X" "$G" "$PASS" "$X" "$Y" "$WARN" "$X" "$R" "$FAILN" "$X"
[[ "$FAILN" -eq 0 ]] && { printf '%sStack looks healthy.%s\n' "$G" "$X"; exit 0; } || { printf '%sSome checks failed — see ✗ above.%s\n' "$R" "$X"; exit 1; }
