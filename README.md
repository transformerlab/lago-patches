# Lago, as deployed by Transformer Lab

Transformer Lab runs [Lago](https://github.com/getlago/lago) v1.51.0 to handle subscription billing for Primus. Lago is licensed under the GNU AGPL-3.0. Section 13 of that licence says that users who interact over a network with a modified version must be offered its source. This repository is that offer: it holds every change we make to Lago.

## Upstream

We use the official images, pinned:

- `getlago/api:v1.51.0`: source at https://github.com/getlago/lago-api/tree/v1.51.0
- `getlago/front:v1.51.0`: source at https://github.com/getlago/lago-front/tree/v1.51.0

## What we change

There is one source modification:

1. **`db/structure.sql`: one line removed.** We delete
   `CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;`.
   Our managed Postgres (Fly Managed Postgres) does not provide the `pg_partman` extension. The rest of the schema works without it. See the comment in the [Dockerfile](Dockerfile) for the full reasoning.

All other changes are packaging only. Upstream's separate containers are folded into one machine:

2. **[Dockerfile](Dockerfile).** Installs nginx on top of `getlago/api`, copies in the front-end's built static assets and its CSP headers, and applies the patch above.
3. **[nginx.conf](nginx.conf).** One server block that serves the front end and path-routes the API, so both answer on one hostname.
4. **[start.sh](start.sh).** Starts the API, the Sidekiq worker, the Clockwork scheduler and nginx in one machine. It also runs migrations and seeds the organisation idempotently on each boot.

No Lago Ruby or JavaScript code is modified.

## Licence

The files in this repository are released under the GNU AGPL-3.0 (see [LICENSE](LICENSE)), the same licence as Lago.
