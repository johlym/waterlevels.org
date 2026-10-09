module Mcp
  # Continuous and daily point reads for series_summary. Mirrors HydrographSeries
  # grain choice without calling HydrographSeries.for (that loads peaks and may
  # read the archive inside the same call).
  #
  # Callers must invoke #collect inside Mcp::ReadOnly.during. When the result
  # is an archive plan, call .read_archive only after the transaction commits.
  class SeriesPoints
    def self.collect(series, range)
      new(series, range).collect
    end

    def self.read_archive(plan)
      return [] if plan.nil? || plan[:keys].blank?

      points = []
      plan[:keys].each do |key|
        DailyArchive::Codec.decode(DailyArchive.store.get(key)).each do |row|
          day = Date.parse(row["d"])
          next if day < plan[:start_on] || day > plan[:end_on]

          points << { t: day.iso8601, v: Mcp::Numbers.round(row["v"]) }
        end
      end
      points.sort_by { |point| point[:t] }
    end

    # Value for one day from an object copied inside the transaction.
    def self.value_on_key(key, day)
      return if key.blank?

      row = DailyArchive::Codec.decode(DailyArchive.store.get(key)).find { |point| point["d"] == day.iso8601 }
      row && row["v"]
    end

    def initialize(series, range)
      @series = series
      @config = HydrographSeries::RANGES.fetch(range)
    end

    # Array of {t:, v:} points, or { archive: plan } when the store must be
    # read after commit.
    def collect
      if @config[:continuous]
        continuous = continuous_points
        return continuous if continuous.any?
      end

      daily_points
    end

    private

    def continuous_points
      @series.continuous_observations
        .where("observed_at >= ?", @config[:duration].ago)
        .order(:observed_at)
        .pluck(:observed_at, :value)
        .map { |observed_at, value| { t: observed_at.iso8601, v: Mcp::Numbers.round(value) } }
    end

    def daily_points
      start_on = @config[:duration].ago.to_date
      end_on = Date.current
      if DailyArchive.reads_enabled?
        { archive: archive_plan(start_on, end_on) }
      else
        postgres_daily(start_on)
      end
    end

    def archive_plan(start_on, end_on)
      years = (start_on.year..end_on.year).to_a
      shard_years = DailyArchiveShard.where(time_series_id: @series.id, year: years).pluck(:year)
      keys = shard_years.sort.map { |year| DailyArchive.object_key(@series.id, year) }
      { start_on: start_on, end_on: end_on, keys: keys }
    end

    def postgres_daily(start_on)
      @series.daily_observations
        .where("observed_on >= ?", start_on)
        .order(:observed_on)
        .pluck(:observed_on, :value)
        .map { |day, value| { t: day.iso8601, v: Mcp::Numbers.round(value) } }
    end
  end
end
