# Email Alerts — Shared Contracts (Wave 0)

Schema names, rule kinds, and event payloads locked for parallel implementation.
`ALERTS_ENABLED` defaults off; flip only at Wave 4 ship.

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
| status | string | `queued`, `sent`, `failed`, `skipped` |
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

**v1:** `flood_category_change`, `threshold`, `digest`  
**Reserved (Phase F):** `rate_of_rise`, `in_range`, `quiet_station`, `approaching_stage`

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
- Jobs: `AlertEvaluationJob`, `AlertDeliveryJob`, `AlertDigestSchedulerJob` (cron `*/15`)
