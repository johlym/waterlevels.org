module DailyArchive
  class Reader
    def initialize(store: DailyArchive.store)
      @store = store
    end

    # Returns chart points [{t:, v:, s?:}, ...] for [start_on, end_on].
    # `s` is included only for derived points.
    def points_for(time_series_id:, start_on:, end_on:)
      return [] unless @store.enabled?
      return [] if start_on.blank? || end_on.blank? || start_on > end_on

      years = (start_on.year..end_on.year).to_a
      shard_years = DailyArchiveShard.where(time_series_id: time_series_id, year: years).pluck(:year)
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
  end
end
