#!/usr/bin/env bash
# One-time bootstrap: generates the local secrets + TLS/realm/runtime files that
# are gitignored (never committed). Idempotent — skips anything already present.
#
#   ./setup.sh   then   docker compose up -d
set -euo pipefail
cd "$(dirname "$0")"

# 1. .env with generated secrets. Render from .env.example via a redirect (not
#    `sed -i`, whose in-place flag differs between GNU and BSD/macOS sed).
if [[ ! -f .env ]]; then
  sed \
    -e "s#^SECRET_KEY_BASE=.*#SECRET_KEY_BASE=$(openssl rand -base64 48)#" \
    -e "s#^MATRIX_ORG_AUDIT_HMAC_KEY=.*#MATRIX_ORG_AUDIT_HMAC_KEY=$(openssl rand -base64 32)#" \
    .env.example > .env
  echo "setup: wrote .env (edit provider keys / creds as needed)"
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

# 2. Self-signed TLS (caddy wildcard edge + keycloak internal)
mkdir -p caddy/tls keycloak/tls
if [[ ! -f caddy/tls/cert.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout caddy/tls/key.pem -out caddy/tls/cert.pem \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:*.${DOMAIN},DNS:auth.${DOMAIN},DNS:studio.${DOMAIN}"
  echo "setup: generated caddy TLS cert"
fi
if [[ ! -f keycloak/tls/cert.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout keycloak/tls/key.pem -out keycloak/tls/cert.pem \
    -subj "/CN=keycloak" -addext "subjectAltName=DNS:keycloak,DNS:localhost"
  echo "setup: generated keycloak TLS cert"
fi
chmod 644 caddy/tls/key.pem keycloak/tls/key.pem

# 3. Keycloak realm — strip the stock-incompatible `kubernetes` IDP from the
#    Strike48 non-prod realm export. Point MATRIX_REALMS_DIR at your checkout.
mkdir -p keycloak/realms
if [[ ! -f keycloak/realms/non-prod-realm.json ]]; then
  src="${MATRIX_REALMS_DIR:-../../init-dev-converged/nix/realms}/non-prod-realm.json"
  [[ -f "$src" ]] || { echo "setup: realm source not found: $src (set MATRIX_REALMS_DIR)" >&2; exit 1; }
  jq 'del(.identityProviders, .identityProviderMappers)' "$src" > keycloak/realms/non-prod-realm.json
  echo "setup: generated keycloak/realms/non-prod-realm.json"
fi

# 4. Studio runtime.exs override — extract the release runtime.exs from the
#    image and append studio-overrides/append.exs (see that file for why).
if [[ ! -f studio-overrides/runtime.exs ]]; then
  docker run --rm --entrypoint sh "${STUDIO_IMAGE}" -c 'cat /app/releases/*/runtime.exs' > studio-overrides/runtime.exs
  cat studio-overrides/append.exs >> studio-overrides/runtime.exs
  echo "setup: generated studio-overrides/runtime.exs"
fi

# 5. Alpaca config — render the LLM_* values from .env into config.toml.
#    (Alpaca doesn't env-substitute these fields, so we do it here.) The API key
#    is NOT baked in — Alpaca's openai provider reads it from OPENAI_API_KEY,
#    which docker-compose feeds from LLM_API_KEY.
: "${LLM_BASE_URL:?set LLM_BASE_URL in .env}"
: "${LLM_CHAT_MODEL:?set LLM_CHAT_MODEL in .env}"
: "${LLM_EMBED_MODEL:?set LLM_EMBED_MODEL in .env}"
: "${LLM_CONTEXT_LIMIT:?set LLM_CONTEXT_LIMIT in .env}"
sed -e "s#@@LLM_BASE_URL@@#${LLM_BASE_URL}#g" \
    -e "s#@@LLM_CHAT_MODEL@@#${LLM_CHAT_MODEL}#g" \
    -e "s#@@LLM_EMBED_MODEL@@#${LLM_EMBED_MODEL}#g" \
    -e "s#@@LLM_CONTEXT_LIMIT@@#${LLM_CONTEXT_LIMIT}#g" \
    alpaca/config.toml.template > alpaca/config.toml
echo "setup: rendered alpaca/config.toml"

echo "setup: done — run 'docker compose up -d'"
