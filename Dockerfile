# Lago, packed into a single Fly machine.
#
# Upstream ships Lago as five containers (api, worker, clock, front, migrate)
# wired by docker-compose. Fly's unit is the app, so this image folds the four
# long-lived ones into one machine behind an nginx front door: the admin UI and
# the REST API answer on one hostname, path-routed, which is what lets Stripe
# webhooks and the UI share a single public URL.
#
# The worker and the clock are NOT optional decorations. Sidekiq (worker) runs
# every job Lago enqueues — invoice generation, webhook delivery, payment
# capture — and Clockwork (clock) is what schedules them: wallet balance
# refresh, recurring top-ups, progressive billing, invoice finalization. A
# deployment missing either looks healthy and silently never bills anyone.
#
# Versions are pinned, never `latest`: an image tag that moves under a running
# billing system is a schema migration nobody approved.

# --- the built SPA ----------------------------------------------------------
# Pulled only for its static assets; its nginx server block is deliberately not
# reused (it listens on 80 and knows nothing about proxying the API).
FROM getlago/front:v1.51.0 AS front

# --- runtime ----------------------------------------------------------------
FROM getlago/api:v1.51.0

# nginx is the only addition. The base is ruby:4.0.2-slim, so this is apt.
RUN apt-get update \
  && apt-get install -y --no-install-recommends nginx \
  && rm -rf /var/lib/apt/lists/* \
  # Debian's nginx package ships a default site on :80 that would shadow ours.
  && rm -f /etc/nginx/sites-enabled/default

# --- the pg_partman patch ---------------------------------------------------
# Fly Managed Postgres does not ship pg_partman (48 extensions available; not
# among them), and Lago's schema wants it.
#
# The MIGRATIONS handle its absence — SetupPartman and PartitionEnrichedEvents
# both check `pg_extension_present?` and skip. But a fresh database never runs
# those: Rails' `db:migrate` sees an empty schema, loads db/structure.sql
# wholesale, and THAT carries an unguarded CREATE EXTENSION. So the one line
# comes out here.
#
# Nothing else in the dump needs the extension. `CREATE SCHEMA partman` and
# `partman.template_public_enriched_events` are plain DDL, and — the load-
# bearing part — `enriched_events` is partitioned BY RANGE with
# `enriched_events_default` attached as the DEFAULT partition, so every insert
# still lands somewhere without partman's monthly children. What we give up is
# those children and the 14-month retention pruning that rides on them.
#
# `grep -q` first so this FAILS THE BUILD if a Lago upgrade moves or renames
# the line, rather than silently shipping an image that dies on first boot.
RUN grep -q '^CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;$' db/structure.sql \
  && sed -i 's|^CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;$|-- pg_partman intentionally omitted: unavailable on Fly MPG (see lago/README.md)|' db/structure.sql

# The SPA, plus `.env.sh` — the script that writes env-config.js at boot so a
# single prebuilt bundle can learn its API URL at runtime.
COPY --from=front /usr/share/nginx/html /usr/share/nginx/html

# Upstream's security headers, verbatim. Taken from the image rather than
# vendored here so they track the front version pinned above.
#
# Its gzip.conf is deliberately NOT copied: it opens with `gzip on;`, which
# Debian's stock nginx.conf already declares at http level, and nginx treats a
# duplicate `gzip` directive as a fatal config error. Our own compression
# settings live in nginx.conf's server block instead.
COPY --from=front /etc/nginx/conf.d/csp.conf  /etc/nginx/conf.d/csp.conf

# Our own server block replaces the front image's.
COPY nginx.conf /etc/nginx/conf.d/lago.conf
COPY start.sh   /app/fly-start.sh
RUN chmod +x /app/fly-start.sh

EXPOSE 8080

CMD ["/app/fly-start.sh"]
