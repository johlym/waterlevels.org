module DailyArchive
  # Persists ContinuousPruneJob / Retention progress so a canceled or retried
  # run can skip work already completed for the same UTC calendar day.
  #
  # Cursor is (phase, after_series_id). Stats and gap alerts accumulate across
  # resumes. Cleared only when the full retention pass finishes successfully.
  class RetentionCheckpoint
    CACHE_KEY = "daily_archive:retention_checkpoint".freeze
    TTL = 2.days
    PHASES = %w[handoff iv_prune daily_prune].freeze

    STAT_KEYS = %w[
      usgs_ensured
      derived
      retrying
      iv_deleted
      iv_blocked
      daily_deleted
      daily_blocked
    ].freeze

    class << self
      def resume_or_start!(as_of:)
        raw = read_raw
        if raw && usable?(raw, as_of)
          return new(raw, resumed: true)
        end

        clear!
        start!(as_of)
      end

      def start!(as_of)
        checkpoint = new(
          {
            "as_of" => as_of.utc.iso8601,
            "phase" => "handoff",
            "after_series_id" => 0,
            "orphans_done" => false,
            "stats" => STAT_KEYS.index_with { 0 },
            "gap_days" => []
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

      def usable?(raw, as_of)
        checkpoint_as_of = parse_time(raw["as_of"])
        return false unless checkpoint_as_of
        return false unless PHASES.include?(raw["phase"].to_s)

        checkpoint_as_of.utc.to_date == as_of.utc.to_date
      end

      def parse_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        Time.zone.parse(value.to_s)
      end
    end

    attr_reader :resumed

    def initialize(data, resumed: false)
      @data = data.stringify_keys
      @data["stats"] = (@data["stats"] || {}).stringify_keys
      @data["gap_days"] = Array(@data["gap_days"])
      @resumed = resumed
    end

    def as_of
      self.class.parse_time(@data["as_of"]) || Time.current
    end

    def phase
      @data["phase"].to_s
    end

    def after_series_id
      @data["after_series_id"].to_i
    end

    def stats
      STAT_KEYS.index_with { |key| @data["stats"][key].to_i }
    end

    def gap_days
      @data["gap_days"].map { |pair| [ pair[0].to_i, pair[1].to_s ] }
    end

    def phase_completed?(name)
      PHASES.index(phase).to_i > PHASES.index(name.to_s).to_i
    end

    def orphans_done?
      ActiveModel::Type::Boolean.new.cast(@data["orphans_done"])
    end

    def series_scope(relation)
      relation.where("time_series.id > ?", after_series_id)
    end

    def add_stats!(**stat_deltas)
      stat_deltas.each do |key, delta|
        canonical = key.to_s
        next unless STAT_KEYS.include?(canonical)

        @data["stats"][canonical] = @data["stats"][canonical].to_i + delta.to_i
      end
      save!
    end

    def mark_series!(series_id, **stat_deltas)
      @data["after_series_id"] = series_id.to_i
      add_stats!(**stat_deltas)
    end

    def mark_orphans_done!(**stat_deltas)
      @data["orphans_done"] = true
      add_stats!(**stat_deltas)
    end

    def complete_phase!(name, **stat_overrides)
      stat_overrides.each do |key, value|
        canonical = key.to_s
        next unless STAT_KEYS.include?(canonical)

        @data["stats"][canonical] = value.to_i
      end

      idx = PHASES.index(name.to_s)
      raise ArgumentError, "unknown retention phase #{name}" unless idx

      if idx >= PHASES.length - 1
        @data["phase"] = name.to_s
        @data["after_series_id"] = 0
      else
        @data["phase"] = PHASES[idx + 1]
        @data["after_series_id"] = 0
        @data["orphans_done"] = false
      end
      save!
    end

    def record_gap!(time_series_id, iso_day)
      pair = [ time_series_id.to_i, iso_day.to_s ]
      return if gap_days.include?(pair)

      @data["gap_days"] << pair
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
