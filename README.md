# Matrix "Prospector" Studio — local dev stack

Runs the real Matrix Studio (+ Alpaca + Construct) locally against Postgres,
Keycloak, rustfs (S3) and a VictoriaMetrics/Logs/Traces telemetry pipeline,
fronted by Caddy. Log in and you land in Prospector Studio.

Only the app and its identity provider are exposed (HTTPS, via Caddy):

| URL | Goes to |
|---|---|
| https://studio.strike48.local:8888 | **Matrix Studio** (log in: `admin` / `admin`) |
| https://auth.strike48.local:8888 | **Keycloak** (realm `non-prod`) |

Everything else — Postgres, rustfs, the telemetry stack, Alpaca, Construct —
runs internally on the compose network.

## Setup

**1. Log in to the private registry** (the Matrix images live in `zot.delivery.strike48.io`).
Get a one-time API key: open <https://zot.delivery.strike48.io> in a browser →
log in via Keycloak → top-right user menu → **API Keys → Generate** → copy the
`zak_…` value. Then:

```bash
docker login zot.delivery.strike48.io -u <your-email>
# paste the zak_… API key as the password (CLI can't do the interactive OIDC flow)
```

**2. Add the hostnames** to `/etc/hosts`:

```bash
127.0.0.1 auth.strike48.local studio.strike48.local
```

**3. Bootstrap the local secrets + TLS/realm/runtime files** (all gitignored):

```bash
./setup.sh
```

This writes `.env` (from `.env.example`, with freshly generated secrets), the
self-signed certs, the stripped Keycloak realm, the studio `runtime.exs`
override, and renders `alpaca/config.toml`. Point `MATRIX_REALMS_DIR` at your
matrix checkout's `nix/realms` if it isn't at the default relative path.

**4. Point it at your LLM.** The stack needs one OpenAI-compatible endpoint for
chat + embeddings. Edit the `LLM_*` block in `.env`:

```bash
LLM_BASE_URL=http://your-endpoint:8000/v1   # anything OpenAI /v1 compatible
LLM_API_KEY=your-bearer-key                 # sent as Authorization: Bearer …
LLM_CHAT_MODEL=your-chat-model-id           # exactly as the server names it
LLM_EMBED_MODEL=your-embedding-model-id
LLM_CONTEXT_LIMIT=32768                      # the chat model's real max_model_len
```

Works with vLLM, SGLang, MLX, LM Studio, LiteLLM, Ollama's `/v1`, or OpenAI
cloud (`LLM_BASE_URL=https://api.openai.com/v1`, `LLM_API_KEY=sk-…`). On macOS,
a model server running on your host is reachable from the containers at
`http://host.docker.internal:<port>/v1`. Then **re-run `./setup.sh`** so the new
values render into `alpaca/config.toml`.

> `LLM_CONTEXT_LIMIT` must match the model's real context window. Studio asks for
> `max_completion_tokens ≈ LLM_CONTEXT_LIMIT / 4`, so setting it larger than the
> server actually serves makes chat fail with an upstream 400.

**5. Bring it up** (pulls the app images from zot on first run):

```bash
docker compose up -d
```

Open **https://studio.strike48.local:8888** and accept the self-signed
certificate warning. You're redirected to Keycloak; log in `admin` / `admin`
and land in Prospector Studio. (Other `non-prod` users exist too, e.g.
`user`, `spiderman`, …, password `matrix123`.)

```bash
docker compose down       # stop (keeps data)
docker compose down -v     # stop and wipe data
```

## Admin console

The admin console is a separate Phoenix endpoint served at
**<https://studio.strike48.local:8888/admin>** (caddy path-routes `/admin/*` to
it). Log in with the same `admin/admin`; the two endpoints share the
host-scoped `_matrix_sid` cookie, so one login covers both. caddy injects the
`x-matrix-auth-server` / `x-matrix-auth-realm` headers the console needs (the
role the gateway plays in production).

## Feature flags (on by default)

Studio auto-creates all feature flags **disabled** at boot. The `feature-flags`
one-shot service then turns them **on for everyone** (global `enabled=true`)
once they exist — so you never need the admin console just to flip flags. Tune
the exceptions with `DISABLED_FLAGS` in `.env` (default `plg_mode,sentry_unmask_data`);
set it empty to enable literally everything. Re-runs idempotently on every `up`.

## How login works (the tricky bits)

- **One HTTPS issuer.** Caddy serves `https://auth.strike48.local:8888`, and
  that exact URL is used by **both** the browser and Studio's backend, so the
  token `iss` matches. HTTPS is required because Studio's OIDC library (oidcc)
  rejects http issuers on non-localhost hosts.
- **Backend → Caddy.** Docker/Podman copy the host's `/etc/hosts` into
  containers, so `auth.strike48.local` resolves to `127.0.0.1` inside Studio.
  The `extra_hosts: ["auth.strike48.local:host-gateway"]` entry overrides that
  so the backend reaches Caddy (it's placed first in `/etc/hosts` and wins).
- **No gateway needed.** Studio's `DevRealmInjector` resolves the realm from
  `MATRIX_KEYCLOAK_REALM`, so it does OIDC standalone.

## Notable env (see `docker-compose.yml`)

| Var | Why |
|---|---|
| `POD_IP=127.0.0.1` | else the Elixir release node name is `studio@` and distribution crashes |
| `MATRIX_CONNECTOR_AUTH_MODE=client_secret` | required at boot or `matrix_connectors` crashes the node |
| `MATRIX_KEYCLOAK_URL=https://auth.strike48.local:8888` + `MATRIX_OIDC_IGNORE_SELF_SIGNED=true` | consistent HTTPS issuer, self-signed cert |
| `DATABASE_URL` / `RAG_DATABASE_URL` → `elixir` / `rag` DBs | Studio's Ecto repos (migrations run on boot) |
| `ALPACA_ADDRESS=alpaca:50051` | **must be set** — the image defaults the Alpaca gRPC address to `localhost:50061` (the connector port), which inside Docker points at the Studio container itself; the gRPC pool then fails and agent/chat requests 404. Points it at the Alpaca service (gRPC :50051). |

## Configuring Alpaca model endpoints

Alpaca is the LLM gateway Studio calls for chat and embeddings. For the common
case you don't touch `alpaca/config.toml` at all — set the `LLM_*` vars in `.env`
(Setup step 4) and `./setup.sh` renders the config for you. The rendered file:

- puts your endpoint on the **provider** (`[providers.openai.proxy].base_url` =
  `LLM_BASE_URL`) and injects `Authorization: Bearer <OPENAI_API_KEY>`, where
  compose feeds `OPENAI_API_KEY` from `LLM_API_KEY`;
- defines two models **keyed by their real ids** (`LLM_CHAT_MODEL`,
  `LLM_EMBED_MODEL`) — with `direct_passthrough` Alpaca sends the key's id
  straight to your server, so the key must match what the server advertises;
- points Studio's tiers (`default`/`smart`/`fast`/`cheap` and `embed`) at them.

Apply changes with `./setup.sh && docker compose up -d alpaca studio` (Studio
re-syncs Alpaca's model list on boot).

### Using a different / additional provider

`alpaca/config.toml.template` ships commented `[models."…"]` blocks for OpenAI
cloud, Anthropic, Gemini and Bedrock. To use one, uncomment it, set its key in
`.env` (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, AWS creds), and repoint the
aliases at it. Keep only **one** enabled chat model — Studio maps its tiers onto
whatever Alpaca exposes, so a stray enabled cloud model can silently capture
traffic (and fail auth).

## Tests

`tests/` holds a Playwright end-to-end test that logs in as `admin`/`admin`,
creates a persona, and holds a conversation — verifying the whole stack
(Keycloak → Studio → Alpaca → your LLM) end to end.

```bash
cd tests
npm install
npx playwright install chromium   # first run only
npx playwright test               # ~10s against a running stack
```

Needs the stack up (`docker compose up -d`) and a working `LLM_*` endpoint. On
Linux hosts where Playwright's bundled Chromium is missing system libraries
(e.g. NixOS), point it at a system browser:
`PLAYWRIGHT_CHROMIUM_PATH=$(command -v google-chrome-stable) npx playwright test`.
On macOS the bundled Chromium works as-is. Override the target with
`STUDIO_URL` / `STUDIO_USER` / `STUDIO_PASS` if you changed the defaults.

## Images

Infra images are public/permissive (Apache 2.0 / PostgreSQL / MIT; the S3
bucket is created with curl+openssl, no AGPL `mc`). The three app images are
Strike48-internal, pulled from `zot.delivery.strike48.io` (see Setup step 1) and
pinned in `.env`:

| `.env` var | Image |
|---|---|
| `STUDIO_IMAGE` | `zot.delivery.strike48.io/strike48/matrix:2026-06-30-release-0.4.0-e79e712` |
| `ALPACA_IMAGE` | `zot.delivery.strike48.io/strike48/alpaca:2026-06-24-1ac5783` |
| `CONSTRUCT_IMAGE` | `zot.delivery.strike48.io/strike48/construct:2026-06-25-main-8e986aa` |

### Running the 0.4.0 release standalone

The 0.4.0 release adds a multi-tenant **Organization** subsystem that, in the
cluster, talks to the Keycloak admin API via a k8s service account. Two things
make it boot in plain compose (no k8s, no gateway):

- `MATRIX_ORG_AUDIT_HMAC_KEY` (in `.env`) — a now-required secret.
- `studio-overrides/runtime.exs` — mounted over the release's `runtime.exs`; it
  sets `org_admin_dev_username`/`org_admin_dev_password` so the Organization
  admin uses Keycloak's master-realm admin (`admin/admin`) via admin-cli instead
  of a k8s SA. (Only exercised when provisioning tenants, not for login.)

> Example credentials throughout — change before any real use.
