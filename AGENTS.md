# AGENTS.md

## Cursor Cloud specific instructions

WaterLevels.org is a single Rails 8.1 / Ruby 4.0.4 app (USGS water-monitoring map). See `README.md` for the full stack and the canonical setup/run/test commands; this section only records non-obvious cloud-environment caveats.

### Toolchain
- Ruby 4.0.4 is managed by `mise` and activated for interactive shells via `~/.bashrc` (`eval "$(mise activate bash)"`). `ruby`, `bundle`, `rubocop`, `foreman`, `sidekiq` resolve through mise. Node/Yarn come from `nvm` (Node 24, pinned by `.nvmrc`, which satisfies `bin/dev`'s Node 20+ requirement); `corepack enable` provides Yarn 1.22.x. The update script refreshes gems/JS deps, so those don't need reinstalling by hand.

### Services must be started each session (no systemd / not auto-started)
- PostgreSQL: `sudo pg_ctlcluster 16 main start`
- Redis: `sudo redis-server --daemonize yes`
- The dev DB connects over the local Unix socket as OS user `ubuntu` (peer auth); a `ubuntu` superuser role exists in Postgres. `config/database.yml` sets no host/user for development, so this role is what makes `bin/rails` work locally.

### `.env` gotchas (file is gitignored; copy from `.env.example`)
- Do NOT keep an empty `DATABASE_URL=` line in `.env`. An empty value makes `bin/rails` abort with "Database URL cannot be empty" in development. Leave `DATABASE_URL` unset (delete the line) locally.
- Do NOT set `REDIS_URL` in `.env` when running the test suite. `dotenv` loads `.env` in the test env too, and a present `REDIS_URL` makes `test/lib/redis_config_test.rb` fail (it asserts the default). `RedisConfig` already defaults to `redis://127.0.0.1:6379/0`, so the app runs without it.
- Daily archive local defaults (`DAILY_ARCHIVE_STORE=local`) are safe in `.env` for `bin/dev`. The test suite ignores `DAILY_ARCHIVE_STORE=local` unless `DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST=1`. After seeding, run `bin/rails archive:export_daily` to populate `tmp/daily_archive` for R2-style `1y` / `3y` chart reads.

### Seed data (preferred for local dev — offline, no API key)
- `bin/rails db:seed` (or `bin/rails db:reset`) loads `db/seeds/demo_state.rb`: 100 Washington stations with 30 days of 15-minute USGS-shaped data. This fully populates the map, state directory, gauge detail cards, trend charts, and measurement tables with no network access. The seed insert is large (~864k rows) and takes ~80s. Example gauge URL: `/gauges/wa` then any station, e.g. `/gauges/wa/99000099-upper-jade-iris-alder-creek-near-site-99`. Site `99000020` is seeded in major flood (gage height above the major stage) for offline flood-alert UI checks.

### Live data (optional)
- Live ingestion (`STATE=xx bin/rails usgs:bootstrap`, `usgs:backfill`) works against the public USGS API without `USGS_API_KEY` (the key is only sent if present) but is rate-limited. The scheduled pipeline needs Redis + Sidekiq. The Sidekiq worker is NOT in `Procfile.dev`; run it separately: `bundle exec sidekiq -C config/sidekiq.yml`.

### Run / lint / test (standard commands; details in `README.md` and `.github/workflows/ci.yml`)
- Run app (dev): `bin/dev` — Puma on `http://127.0.0.1:3000` plus esbuild and Tailwind watchers.
- Lint: `bin/rubocop`. Security: `bin/brakeman --no-pager` and `bin/bundler-audit`.
- Tests: `bin/rails test` (Postgres must be running; test DB prepared via `bin/rails db:test:prepare`).
