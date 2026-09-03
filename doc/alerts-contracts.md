# Email Alerts — As-built contracts

Shipped with #242 (schema, signup, evaluation, digests), #247 (`notifications_worker`), and #258 (batched evaluation). Operator runbook: [`README.md`](../README.md#email-alerts-operator). Tip SLA: [`alerts-freshness-sla.md`](alerts-freshness-sla.md).

`ALERTS_ENABLED` still defaults **off**. Flip only after `notifications_worker` is scaled.

## Feature flag

- Env: `ALERTS_ENABLED` — truthy values: `1`, `true`, `yes`, `on` (case-insensitive)
- Helper: `AlertsConfig.enabled?` / `.disabled?` (`app/models/alerts_config.rb`)
- When false:
  - Hide CTAs (gauge signup, nav, map)
  - Subscription routes return **404** (`AlertsFeatureGate`) — not a home redirect
  - Evaluation, delivery, digest, and quiet-scan jobs no-op immediately
  - `AlertEventRecorder` **still writes** `alert_events` from tip/flood sync
  - Scheduler on `worker` still enqueues digest (`*/15`) and quiet scan (`10 * * * *`) onto `notifications`

## Tables

Schema from `db/migrate/20260829050000_create_email_alerts_schema.rb` — Wave 0 column names shipped unchanged.

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
| kind | string | `flood_category_change`, `reading_change`, `quiet_station`, `resume_station` |
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
| status | string | `queued`, `sent`, `failed`, `skipped` |
| sent_at | datetime |
| metadata | jsonb |

### `subscriber_tokens`
| Column | Type | Notes |
|--------|------|-------|
| subscriber_id | fk | |
| purpose | string | `manage`, `verify`, `unsubscribe` |
| token_digest | string, unique | SHA256 of raw token |
| expires_at | datetime | `verify` 48h; `manage` 2y (rotated); `unsubscribe` 30d (signup) or 2y (alert mail) |
| used_at | datetime | set on unsubscribe |

## Rule kinds

Registry: `app/models/alert_rule_kinds.rb`. New watches get flood + digest via `StationWatch#ensure_default_rules!`. Threshold is created **disabled** from the manage UI.

| Kind | Evaluator | Manage UI | Delivery |
|------|-----------|-----------|----------|
| `flood_category_change` | `Alerts::FloodEvaluator` | Yes | `AlertMailer#flood_category_change` |
| `threshold` | `Alerts::ThresholdEvaluator` | Yes | `AlertMailer#threshold_crossed` |
| `digest` | `Alerts::DigestBuilder` (scheduler) | Yes (include toggle) | `AlertMailer#daily_digest` |
| `rate_of_rise` | `Alerts::RateOfRiseEvaluator` | No | Mailer stub (`stub_phase_f!`) |
| `in_range` | `Alerts::InRangeEvaluator` | No | Mailer stub |
| `quiet_station` | Event from `AlertQuietScanJob` | No | **Do not enable** — `AlertDeliveryJob` has no case |
| `approaching_stage` | None | No | No |

`Subscriber.active` / `Alerts::WatchedLocations` require verified + not unsubscribed + not paused. Quiet-hours columns exist; there is no manage UI for them. `AlertMailer#verify_email` is unused — signup sends `subscription_confirmation`.

### Params shapes

```json
// threshold
{ "parameter": "water_level"|"discharge", "op": "above"|"below", "value": 12.5, "duration_minutes": 30, "cooldown_minutes": 360, "hysteresis": 0.2 }

// digest (usually subscriber-level; rule enables inclusion)
{ "include": true }

// flood_category_change
{ "notify_clear": true, "min_severity": "action" }

// rate_of_rise (Phase F — evaluator only)
{ "parameter": "water_level", "window_hours": 3, "delta": 1.5, "cooldown_minutes": 360 }

// in_range (Phase F — evaluator only)
{ "parameter": "discharge", "min": 800, "max": 2000, "on": "enter"|"leave"|"both" }
```

Flood `min_severity` ranks: `no_flooding` < `action` < `minor` < `moderate` < `major`.

## Event payloads

```json
// flood_category_change
{ "from": "no_flooding", "to": "major", "observed_at": "ISO8601" }

// reading_change
{ "parameter": "water_level", "from": 10.1, "to": 12.4, "unit": "ft", "observed_at": "ISO8601" }
```

## Routes (not under `/alerts`)

404 when `AlertsConfig.disabled?`. Session-backed except the gauge-page POST (honeypot + Turnstile + 20/hr IP).

- `GET /subscriptions` — request manage link
- `POST /subscriptions` — gauge signup **or** manage-link request (`intent=manage_link`)
- `GET /subscriptions/verify/:token`
- `GET /subscriptions/manage/:token`
- `PATCH /subscriptions/manage/:token`
- `DELETE /subscriptions/manage/:token/watches/:id`
- `POST /subscriptions/manage/:token/pause` / `…/unpause`
- `GET|POST /subscriptions/unsubscribe/:token`

## Sidekiq

- Queue: `notifications` → `notifications_worker` (`config/sidekiq_notifications.yml`, concurrency 1)
- Scheduler stays on `worker` (`config/sidekiq.yml`)
- Jobs:
  - `AlertEvaluationBatchJob` — drains `AlertEvaluationEnqueueBuffer` (`FLUSH_DELAY` = 90s). No flag check; buffer scheduling is gated.
  - `AlertEvaluationJob` — per-location eval (`PENDING_WINDOW` = 2h)
  - `AlertDeliveryJob` — flood/threshold/digest (skips inactive / quiet hours except digest)
  - `AlertDigestSchedulerJob` — cron `*/15`
  - `AlertQuietScanJob` — cron `10 * * * *` (6h quiet threshold)
- Tip/flood sync records `alert_events` for all stations but only **watched** locations enter the evaluation buffer (`Alerts::WatchedLocations`, 5 min cache). Multiple events for the same station coalesce to one batch flush.
