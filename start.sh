#!/bin/bash
# Boot the whole Lago stack in one machine: migrate, then supervise four
# long-lived processes.
#
# The supervision contract is deliberately blunt — if ANY of the four exits,
# this script tears the rest down and exits non-zero, so Fly restarts the
# machine. A Lago running with a dead Sidekiq is worse than a Lago that is
# visibly down: invoices queue up, webhooks never deliver, and every health
# check still passes because Rails is fine.
set -euo pipefail

log() { echo "[lago-boot] $*"; }

# --- migrations -----------------------------------------------------------
# Run here rather than as a Fly release_command because a failed release
# blocks the deploy with the logs in a machine that is already gone. Safe
# because this app is pinned to ONE machine (see fly.toml: min/max 1, deployed
# --ha=false) and Rails takes a Postgres advisory lock for the duration anyway.
#
# `db:create` is deliberately not run: Fly Managed Postgres hands us an
# existing database and a role that may not hold CREATEDB, so upstream's
# migrate.sh would abort on a permission error where there is nothing to do.
#
# NOTE on pg_partman: unavailable on Fly MPG. On a FRESH database this task
# loads db/structure.sql wholesale rather than replaying migrations, and that
# dump carries an unguarded CREATE EXTENSION — so the Dockerfile strips the one
# line. On an EXISTING database only new migrations run, and Lago guards its
# partman ones behind `pg_extension_present?`. Either way `enriched_events`
# keeps its DEFAULT partition and accepts writes; what is lost is the monthly
# child partitions and their 14-month retention pruning. See README.
log "running migrations"
bundle exec rails db:migrate

log "seeding predefined roles"
bundle exec rails roles:seed_predefined

# Idempotent (find_or_create_by! throughout) and honours LAGO_ORG_API_KEY, so
# running it on every boot re-asserts the API key we provisioned rather than
# minting a new one.
if [ "${LAGO_CREATE_ORG:-false}" = "true" ]; then
  log "seeding organization"
  bundle exec rails signup:seed_organization
fi

# --- the SPA's runtime config ---------------------------------------------
# One prebuilt bundle, many deployments: .env.sh writes env-config.js from the
# environment. It uses relative paths, hence the cd.
log "writing front env-config.js (API_URL=${API_URL:-unset})"
( cd /usr/share/nginx/html && ./.env.sh )

# --- supervise ------------------------------------------------------------
rm -f ./tmp/pids/server.pid

pids=()

start() {
  local name="$1"; shift
  log "starting $name"
  "$@" &
  pids+=("$!")
}

shutdown() {
  log "shutting down"
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait
}
trap shutdown TERM INT

start web    bundle exec rails s -b :: -p 3000
start worker bundle exec sidekiq -C config/sidekiq/sidekiq.yml
start clock  bundle exec clockwork ./clock.rb
start nginx  nginx -g "daemon off;"

# `wait -n` returns as soon as the FIRST child exits, whichever it is. That is
# the whole point: any one of them dying makes this deployment wrong.
set +e
wait -n
code=$?
log "a supervised process exited (status $code) — taking the machine down"
shutdown
exit "${code:-1}"
