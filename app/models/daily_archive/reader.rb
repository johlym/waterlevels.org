module DailyArchive
  class Reader
    def initialize(store: DailyArchive.store)
      @store = store
    end

    # One shard-year lookup for many series. points_for uses the index when the
    # requested years were part of this preload, and falls back to its own query
    # when they were not (a partial index must not look like "no shard").
    def self.with_shard_years(time_series_ids, years:)
      ids = Array(time_series_ids).map(&:to_i).uniq
      year_list = Array(years).map(&:to_i).uniq
      by_series = Hash.new { |found, id| found[id] = [] }
      if ids.any? && year_list.any?
        DailyArchiveShard.where(time_series_id: ids, year: year_list).pluck(:time_series_id, :year).each do |id, year|
          by_series[id.to_i] << year.to_i
        end
      end
      ids.each { |id| by_series[id] }

      previous = Thread.current[:daily_archive_shard_years]
      Thread.current[:daily_archive_shard_years] = { years: year_list, by_series: by_series }
      yield
    ensure
      Thread.current[:daily_archive_shard_years] = previous
    end

    # Returns chart points [{t:, v:, s?:}, ...] for [start_on, end_on].
    # `s` is included only for derived points.
    def points_for(time_series_id:, start_on:, end_on:)
      return [] unless @store.enabled?
      return [] if start_on.blank? || end_on.blank? || start_on > end_on

      years = (start_on.year..end_on.year).to_a
      shard_years = shard_years_for(time_series_id, years)
      return [] if shard_years.empty?

      points = []
      shard_years.sort.each do |year|
        key = DailyArchive.object_key(time_series_id, year)
        Codec.decode(@store.get(key)).each do |row|
          day = Date.parse(row["d"])
          next if day < start_on || day > end_on

          point = { t: day.iso8601, v: row["v"].to_f }
          point[:s] = DailyArchive::SOURCE_DERIVED if row["s"] == DailyArchive::SOURCE_DERIVED
          points << point
        end
      end
      points.sort_by { |p| p[:t] }
    end

    def value_on(time_series_id:, day:)
      day = day.to_date
      point = points_for(time_series_id: time_series_id, start_on: day, end_on: day).first
      point && point[:v]
    end

    def covers_range?(time_series_id:, start_on:, end_on:)
      return false if start_on.blank? || end_on.blank? || start_on > end_on

      shards = DailyArchiveShard.where(
        time_series_id: time_series_id,
        year: start_on.year..end_on.year
      ).to_a
      return false if shards.empty?

      # Coarse coverage: every calendar year in range has a shard whose min/max span that year segment.
      (start_on.year..end_on.year).all? do |year|
        shard = shards.find { |s| s.year == year }
        next false unless shard

        year_start = [ start_on, Date.new(year, 1, 1) ].max
        year_end = [ end_on, Date.new(year, 12, 31) ].min
        shard.min_on && shard.max_on && shard.min_on <= year_start && shard.max_on >= year_end
      end
    end

    private

    def shard_years_for(time_series_id, years)
      frame = Thread.current[:daily_archive_shard_years]
      id = time_series_id.to_i
      if frame && frame[:by_series].key?(id) && years.all? { |year| frame[:years].include?(year.to_i) }
        have = frame[:by_series][id]
        return years.map(&:to_i).select { |year| have.include?(year) }
      end

      DailyArchiveShard.where(time_series_id: time_series_id, year: years).pluck(:year)
    end
  end
end
