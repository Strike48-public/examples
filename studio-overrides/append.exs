# ── Local-compose override ──────────────────────────────────────────────────
# Appended to the studio image's release runtime.exs by ./setup.sh.
#
# matrix 0.4.0's Organization admin-token manager (MatrixCore.Organization.
# AdminTokenManager) manages tenant realms via the Keycloak admin API. In the
# cluster it uses a k8s service account; standalone it falls back to
# client_secret with no secret and crashes at boot. It has a DEV path
# (fetch_admin_cli_token) that logs into the master realm via admin-cli with
# org_admin_dev_username/password — wire that to the Keycloak bootstrap admin so
# it boots without k8s. (Only exercised when provisioning tenants, not login.)
if config_env() == :prod do
  config :matrix_core,
    org_admin_dev_username: System.get_env("MATRIX_ORG_ADMIN_DEV_USERNAME") || "admin",
    org_admin_dev_password: System.get_env("MATRIX_ORG_ADMIN_DEV_PASSWORD") || "admin"
end
