#!/bin/sh
# Turn Matrix feature flags ON for everyone, without the admin console.
#
# Studio auto-creates every known flag (disabled) in the `feature_flags` table
# on boot. This one-shot waits for that, then flips them all on globally
# (enabled = true with empty targeting arrays = on for everyone), except any
# listed in DISABLED_FLAGS. Idempotent — safe to re-run on every `up`.
set -eu

# Denylist entries are matched with SQL LIKE, so an entry can be an exact flag
# name (plg_mode) or a prefix pattern (policy_control_%).
DENY="${DISABLED_FLAGS:-plg_mode,sentry_unmask_data}"
PSQL="psql -v ON_ERROR_STOP=1 -tA"

echo "feature-flags: waiting for Studio to populate the feature_flags table…"
i=0
until [ "$($PSQL -c 'SELECT count(*) FROM feature_flags' 2>/dev/null || echo 0)" -gt 0 ]; do
  i=$((i + 1))
  [ "$i" -ge 120 ] && { echo "feature-flags: flags never appeared (is Studio up?)" >&2; exit 1; }
  sleep 3
done

echo "feature-flags: enabling all flags except: ${DENY}"
$PSQL -c "
  UPDATE feature_flags
     SET enabled = true,
         enabled_for_users = '{}',
         enabled_for_tenants = '{}',
         enabled_for_hostnames = '{}',
         updated_at = NOW()
   WHERE NOT (name LIKE ANY (string_to_array('${DENY}', ',')));
"
# The denylist is authoritative: force matching flags OFF even if already on.
$PSQL -c "
  UPDATE feature_flags
     SET enabled = false, updated_at = NOW()
   WHERE name LIKE ANY (string_to_array('${DENY}', ','));
"
echo "feature-flags: done — $($PSQL -c 'SELECT count(*) FILTER (WHERE enabled) FROM feature_flags') of $($PSQL -c 'SELECT count(*) FROM feature_flags') flags enabled"
