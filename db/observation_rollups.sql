-- Hourly counts of observation rows, maintained by statement-level triggers.
-- Lifetime, 24h, 7d, and "today" sums read this table instead of COUNT(*).
--
-- Bucket is date_trunc('hour', observed_at). A row with no timestamp (peak
-- rows may omit observed_at) lands on the Unix epoch so it still counts
-- toward the lifetime total and stays outside every recent window.
-- selected_point_count uses time_series.selected_for_display at write time.
-- A weekly rebuild repairs selection changes and any missed delta.
-- Shard is time_series_id % 16 so one hour is not a single hot row.

CREATE OR REPLACE FUNCTION observation_rollups_apply_observed_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_delta integer := CASE TG_OP WHEN 'INSERT' THEN 1 WHEN 'DELETE' THEN -1 ELSE 0 END;
  v_dataset smallint := CASE TG_TABLE_NAME
    WHEN 'continuous_observations' THEN 0
    WHEN 'peak_observations' THEN 2
    ELSE NULL
  END;
BEGIN
  IF v_delta = 0 OR v_dataset IS NULL THEN
    RETURN NULL;
  END IF;

  -- A second statement drops buckets that landed on zero. Postgres will not
  -- update and delete the same row in one statement.
  INSERT INTO observation_rollups (
    dataset, bucket, shard, point_count, selected_point_count, created_at, updated_at
  )
  SELECT
    v_dataset,
    bucket,
    shard,
    v_delta * points,
    v_delta * selected_points,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM (
    SELECT
      COALESCE(
        date_trunc('hour', c.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
        TIMESTAMPTZ '1970-01-01 00:00:00+00'
      ) AS bucket,
      mod(c.time_series_id, 16)::smallint AS shard,
      count(*)::bigint AS points,
      count(*) FILTER (WHERE COALESCE(ts.selected_for_display, false))::bigint AS selected_points
    FROM changed_rows c
    LEFT JOIN time_series ts ON ts.id = c.time_series_id
    GROUP BY 1, 2
  ) AS delta_rows
  ON CONFLICT (dataset, bucket, shard) DO UPDATE
  SET point_count = observation_rollups.point_count + EXCLUDED.point_count,
      selected_point_count = observation_rollups.selected_point_count + EXCLUDED.selected_point_count,
      updated_at = CURRENT_TIMESTAMP;

  DELETE FROM observation_rollups
  WHERE dataset = v_dataset
    AND point_count = 0
    AND selected_point_count = 0;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION observation_rollups_apply_observed_on()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_delta integer := CASE TG_OP WHEN 'INSERT' THEN 1 WHEN 'DELETE' THEN -1 ELSE 0 END;
BEGIN
  IF v_delta = 0 OR TG_TABLE_NAME <> 'daily_observations' THEN
    RETURN NULL;
  END IF;

  INSERT INTO observation_rollups (
    dataset, bucket, shard, point_count, selected_point_count, created_at, updated_at
  )
  SELECT
    1::smallint,
    bucket,
    shard,
    v_delta * points,
    v_delta * selected_points,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM (
    SELECT
      date_trunc('hour', (c.observed_on::timestamp AT TIME ZONE 'UTC')) AS bucket,
      mod(c.time_series_id, 16)::smallint AS shard,
      count(*)::bigint AS points,
      count(*) FILTER (WHERE COALESCE(ts.selected_for_display, false))::bigint AS selected_points
    FROM changed_rows c
    LEFT JOIN time_series ts ON ts.id = c.time_series_id
    GROUP BY 1, 2
  ) AS delta_rows
  ON CONFLICT (dataset, bucket, shard) DO UPDATE
  SET point_count = observation_rollups.point_count + EXCLUDED.point_count,
      selected_point_count = observation_rollups.selected_point_count + EXCLUDED.selected_point_count,
      updated_at = CURRENT_TIMESTAMP;

  DELETE FROM observation_rollups
  WHERE dataset = 1
    AND point_count = 0
    AND selected_point_count = 0;

  RETURN NULL;
END;
$$;

-- One grouped scan of each fact table. SHARE locks block writes for the
-- statement so a trigger cannot add a delta that this rebuild then deletes
-- or double-counts. Readers of admin_counters keep the previous snapshot.
CREATE OR REPLACE FUNCTION observation_rollups_rebuild()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  LOCK TABLE continuous_observations IN SHARE MODE;
  LOCK TABLE daily_observations IN SHARE MODE;
  LOCK TABLE peak_observations IN SHARE MODE;

  DELETE FROM observation_rollups;

  INSERT INTO observation_rollups (
    dataset, bucket, shard, point_count, selected_point_count, created_at, updated_at
  )
  SELECT
    0::smallint,
    COALESCE(
      date_trunc('hour', c.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      TIMESTAMPTZ '1970-01-01 00:00:00+00'
    ),
    mod(c.time_series_id, 16)::smallint,
    count(*)::bigint,
    count(*) FILTER (WHERE COALESCE(ts.selected_for_display, false))::bigint,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM continuous_observations c
  LEFT JOIN time_series ts ON ts.id = c.time_series_id
  GROUP BY 2, 3

  UNION ALL

  SELECT
    1::smallint,
    date_trunc('hour', (d.observed_on::timestamp AT TIME ZONE 'UTC')),
    mod(d.time_series_id, 16)::smallint,
    count(*)::bigint,
    count(*) FILTER (WHERE COALESCE(ts.selected_for_display, false))::bigint,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM daily_observations d
  LEFT JOIN time_series ts ON ts.id = d.time_series_id
  GROUP BY 2, 3

  UNION ALL

  SELECT
    2::smallint,
    COALESCE(
      date_trunc('hour', p.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
      TIMESTAMPTZ '1970-01-01 00:00:00+00'
    ),
    mod(p.time_series_id, 16)::smallint,
    count(*)::bigint,
    count(*) FILTER (WHERE COALESCE(ts.selected_for_display, false))::bigint,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM peak_observations p
  LEFT JOIN time_series ts ON ts.id = p.time_series_id
  GROUP BY 2, 3;
END;
$$;

DROP TRIGGER IF EXISTS observation_rollups_insert ON continuous_observations;
DROP TRIGGER IF EXISTS observation_rollups_delete ON continuous_observations;
DROP TRIGGER IF EXISTS observation_rollups_insert ON daily_observations;
DROP TRIGGER IF EXISTS observation_rollups_delete ON daily_observations;
DROP TRIGGER IF EXISTS observation_rollups_insert ON peak_observations;
DROP TRIGGER IF EXISTS observation_rollups_delete ON peak_observations;

CREATE TRIGGER observation_rollups_insert
AFTER INSERT ON continuous_observations
REFERENCING NEW TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_at();

CREATE TRIGGER observation_rollups_delete
AFTER DELETE ON continuous_observations
REFERENCING OLD TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_at();

CREATE TRIGGER observation_rollups_insert
AFTER INSERT ON daily_observations
REFERENCING NEW TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_on();

CREATE TRIGGER observation_rollups_delete
AFTER DELETE ON daily_observations
REFERENCING OLD TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_on();

CREATE TRIGGER observation_rollups_insert
AFTER INSERT ON peak_observations
REFERENCING NEW TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_at();

CREATE TRIGGER observation_rollups_delete
AFTER DELETE ON peak_observations
REFERENCING OLD TABLE AS changed_rows
FOR EACH STATEMENT
EXECUTE FUNCTION observation_rollups_apply_observed_at();
