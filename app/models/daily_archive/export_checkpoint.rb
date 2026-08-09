module DailyArchive
  # Cursor for DailyArchiveExportJob so a canceled catch-up export resumes
  # after the last completed series instead of rewriting every year shard.
  class ExportCheckpoint
    CACHE_KEY = "daily_archive:export_checkpoint".freeze
    TTL = 2.days

    class << self
      def resume_or_start!(only_cold:, time_series_ids: nil)
        fingerprint = fingerprint_for(only_cold: only_cold, time_series_ids: time_series_ids)
        raw = read_raw
        if raw && raw["fingerprint"] == fingerprint
          return new(raw, resumed: true)
        end

        clear!
        start!(fingerprint)
      end

      def start!(fingerprint)
        checkpoint = new(
          {
            "fingerprint" => fingerprint,
            "after_series_id" => 0,
            "series" => 0,
            "points" => 0
          },
          resumed: false
        )
        checkpoint.save!
        checkpoint
      end

      def clear!
        Rails.cache.delete(CACHE_KEY)
      end

      def read_raw
        raw = Rails.cache.read(CACHE_KEY)
        raw.is_a?(Hash) ? raw.stringify_keys : nil
      end

      def fingerprint_for(only_cold:, time_series_ids:)
        ids = Array(time_series_ids).map(&:to_i).sort
        "cold=#{only_cold ? 1 : 0};ids=#{ids.join(",")}"
      end
    end

    attr_reader :resumed

    def initialize(data, resumed: false)
      @data = data.stringify_keys
      @resumed = resumed
    end

    def after_series_id
      @data["after_series_id"].to_i
    end

    def series
      @data["series"].to_i
    end

    def points
      @data["points"].to_i
    end

    # Advance the series cursor. Only bump exported series/points when work landed.
    def mark_series!(series_id, exported_points: 0, exported_series: nil)
      @data["after_series_id"] = series_id.to_i
      series_delta = exported_series.nil? ? (exported_points.to_i.positive? ? 1 : 0) : exported_series.to_i
      @data["series"] = series.to_i + series_delta
      @data["points"] = points.to_i + exported_points.to_i
      save!
    end

    def clear!
      self.class.clear!
    end

    def save!
      Rails.cache.write(CACHE_KEY, @data, expires_in: TTL)
      self
    end
  end
end
