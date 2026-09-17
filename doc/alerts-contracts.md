# Email Alerts — Shared Contracts

As-built contracts for the live alerts product (behind `ALERTS_ENABLED`, default off).
Public FAQ: `/faq#email-alerts`. Operator notes: [`alerts-freshness-sla.md`](alerts-freshness-sla.md) and the README “Email alerts” section.

## Feature flag

- Env: `ALERTS_ENABLED` — truthy values: `1`, `true`, `yes`, `on`
- Helper: `AlertsConfig.enabled?`
- When false: hide CTAs, skip evaluation/delivery jobs, 404 subscription routes (or redirect home)

## Tables

### `subscribers`
| Column | Type | Notes |
|--------|------|-------|
| email | string, unique, not null | downcased |
| verified_at | datetime | nil until double opt-in |
| time_zone | string, not null | IANA, default `America/New_York` |
| digest_hour | integer, not null | 0–23, default 7 |
| digest_minute | integer, not null | 0 or 30, default 0 |
| digest_enabled | boolean, not null | default true |
| digest_last_sent_on | date | local calendar day last digest sent |
| paused_at | datetime | soft pause |
| unsubscribed_at | datetime | hard stop |
| quiet_hours_start_minute | integer | minutes from midnight local; nil = off |
| quiet_hours_end_minute | integer | |

### `station_watches`
| Column | Type |
|--------|------|
| subscriber_id | fk |
| monitoring_location_id | fk |
| label | string, optional |
| unique (subscriber_id, monitoring_location_id) |

### `alert_rules`
| Column | Type | Notes |
|--------|------|-------|
| station_watch_id | fk | |
| kind | string, not null | see enum below |
| enabled | boolean, default true | |
| params | jsonb, default {} | kind-specific |
| last_fired_at | datetime | cool-down |
| armed | boolean, default true | hysteresis re-arm |

### `alert_events`
| Column | Type | Notes |
|--------|------|-------|
| monitoring_location_id | fk | |
| kind | string | `flood_category_change`, `reading_change`, … |
| occurred_at | datetime | |
| payload | jsonb | |
| dedupe_key | string, unique | idempotency |

### `alert_deliveries`
| Column | Type |
|--------|------|
| subscriber_id | fk |
| alert_event_id | fk, optional |
| alert_rule_id | fk, optional |
| mailer_action | string |
| status | string | `queued`, `sending`, `sent`, `failed`, `skipped` |
| sent_at | datetime |
| metadata | jsonb |

### `subscriber_tokens`
| Column | Type | Notes |
|--------|------|-------|
| subscriber_id | fk | |
| purpose | string | `manage`, `verify`, `unsubscribe` |
| token_digest | string, unique | SHA256 of raw token |
| expires_at | datetime | manage tokens long-lived; verify short |
| used_at | datetime | |

## Rule kinds

**v1 (user-created):** `flood_category_change`, `threshold`, `digest`  
**Implemented operationally (not a user-created rule kind):** `quiet_station` — `AlertQuietScanJob` (hourly `:10`) + `Alerts::QuietStationDetector` (6h quiet threshold, watched stations only). Delivery path is live.  
**Reserved (Phase F user-created rules):** `rate_of_rise`, `in_range`, `approaching_stage`

### Params shapes

```json
// threshold
{ "parameter": "water_level"|"discharge", "op": "above"|"below", "value": 12.5, "duration_minutes": 30, "cooldown_minutes": 360, "hysteresis": 0.2 }

// digest (usually subscriber-level; rule enables inclusion)
{ "include": true }

// flood_category_change
{ "notify_clear": true, "min_severity": "action" }

// rate_of_rise (Phase F)
{ "parameter": "water_level", "window_hours": 3, "delta": 1.5, "cooldown_minutes": 360 }

// in_range (Phase F)
{ "parameter": "discharge", "min": 800, "max": 2000, "on": "enter"|"leave"|"both" }
```

## Event payloads

```json
// flood_category_change
{ "from": "no_flooding", "to": "major", "observed_at": "ISO8601" }

// reading_change
{ "parameter": "water_level", "from": 10.1, "to": 12.4, "unit": "ft", "observed_at": "ISO8601" }
```

## Routes (not under `/alerts`)

- `GET /subscriptions` — request manage link
- `POST /subscriptions` — create/verify watch signup
- `GET /subscriptions/verify/:token`
- `GET /subscriptions/manage/:token`
- `PATCH /subscriptions/manage/:token`
- `GET|POST /subscriptions/unsubscribe/:token`

## Sidekiq

- Queue: `notifications`
- Jobs: `AlertEvaluationBatchJob` (debounced drain of `AlertEvaluationEnqueueBuffer`; mid-loop failure re-buffers remaining location IDs), `AlertEvaluationJob` (per-location eval, invoked by batch), `AlertDeliveryJob`, `AlertDigestSchedulerJob` (cron `*/15`), `AlertQuietScanJob` (cron hourly `:10`)
- Tip/flood sync records `alert_events` for all stations but only **watched** locations enter the evaluation buffer (`Alerts::WatchedLocations`). Multiple events for the same station coalesce to one batch flush (~90s debounce).
- Delivery uniqueness: partial unique index on `(subscriber_id, alert_event_id, alert_rule_id)`. `digest_last_sent_on` updates only after a successful send.
- Manage tokens (`Subscriber#manage_token!`) are HMAC-stable per subscriber (not rotated on every delivery). Verify tokens expire in 48 hours.
- Production gauge signup requires `TURNSTILE_SECRET`. Timezone is JS-detected (hidden on the gauge form). Cap: `ALERTS_MAX_WATCHES` (default 25).
