# WaterLevels.org

Rails 8.1 / Ruby 4 app that maps USGS water monitoring locations (water level, flow, temperature) with cached station and state pages.

## Stack

- PostgreSQL, Redis, Sidekiq (+ sidekiq-scheduler)
- Tailwind CSS v4, esbuild, Stimulus, Leaflet, Chart.js
- ViewComponent (sidecar)

## Local setup

```bash
rvm use 4.0.4
nvm use 20
bundle install
yarn install
createdb waterlevels_development waterlevels_test
bin/rails db:migrate
cp .env.example .env   # add USGS_API_KEY
bin/dev
```

Bootstrap USGS data (rate-limit aware; may take a long time nationally):

```bash
bin/rails usgs:bootstrap
```

Or enqueue:

```bash
bin/rails runner "StationCatalogSyncJob.perform_later"
```

## Tests

```bash
bundle exec rspec
```

## Heroku

- Dynos: `web`, `worker`
- Add-ons: Postgres, Redis
- Set `USGS_API_KEY`, `REDIS_URL`, `DATABASE_URL`
- Put Cloudflare in front; honor `Cache-Control` / `Cache-Tag` from the app

## Contact form

`GET /contact` is served by `PagesController` (not edge-cached). `POST /contact` uses `ContactMessage` + `invisible_captcha` + Cloudflare Turnstile, then `ContactMailer`.

Set in `.env`:

- `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` (provision with turnstile-spin)
- Optional `TURNSTILE_SITEVERIFY_URL` (managed Worker from spin)
- `CONTACT_TO_EMAIL` / `MAIL_FROM`
- `BENTO_SITE_UUID`, `BENTO_PUBLISHABLE_KEY`, `BENTO_SECRET_KEY` (Action Mailer via `bento-actionmailer` + `premailer-rails`)

## Notes

- Map may be empty until catalog sync lands locations.
- Temperature is stored in °C; UI defaults to °F via a preference cookie.
- Local PostGIS is optional; nearby stations use haversine precompute, map bbox uses lat/lon indexes.
