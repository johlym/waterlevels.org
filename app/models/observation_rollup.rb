# Hourly, sharded counts of continuous, daily, and peak observations.
# Statement-level triggers in db/observation_rollups.sql maintain the rows.
# Windows are exact to the hour: a bucket is included when its hour start is
# at or after the truncated cutoff. "Today" is the Pacific civil day, which
# lands on an hour boundary.
class ObservationRollup < ApplicationRecord
  DATASETS = { continuous: 0, daily: 1, peak: 2 }.freeze

  def self.summary(now: Time.current)
    zone = Time.find_zone!(SiteStats::UPDATES_TIME_ZONE)
    local_now = now.in_time_zone(zone)
    today_start = local_now.beginning_of_day
    binds = {
      since_24h: (now - 24.hours).beginning_of_hour,
      since_7d: (now - 7.days).beginning_of_hour,
      today_start: today_start,
      today_end: today_start + 1.day
    }
    rows = connection.select_all(sanitize_sql_array([ SUMMARY_SQL, binds ]))
    by_dataset = rows.index_by { |row| row["dataset"].to_i }

    DATASETS.transform_values do |dataset|
      row = by_dataset[dataset] || {}
      {
        lifetime: row["lifetime"].to_i,
        last_24h: row["last_24h"].to_i,
        last_7d: row["last_7d"].to_i,
        last_24h_selected: row["last_24h_selected"].to_i,
        today: row["today"].to_i
      }
    end
  end

  # Replace every rollup row from the fact tables. Weekly, beside retention.
  def self.rebuild!
    connection.execute("SELECT observation_rollups_rebuild()")
  end

  SUMMARY_SQL = <<~SQL.squish.freeze
    SELECT dataset,
           COALESCE(SUM(point_count), 0) AS lifetime,
           COALESCE(SUM(point_count) FILTER (WHERE bucket >= :since_24h), 0) AS last_24h,
           COALESCE(SUM(point_count) FILTER (WHERE bucket >= :since_7d), 0) AS last_7d,
           COALESCE(SUM(selected_point_count) FILTER (WHERE bucket >= :since_24h), 0) AS last_24h_selected,
           COALESCE(SUM(point_count) FILTER (WHERE bucket >= :today_start AND bucket < :today_end), 0) AS today
    FROM observation_rollups
    GROUP BY dataset
  SQL
  private_constant :SUMMARY_SQL
end
