require "test_helper"

module DailyArchive
  class ExporterTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      ExportCheckpoint.clear!
      @series = create(:time_series)
      DailyObservation.create!(time_series: @series, observed_on: 20.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 2.0)
    end

    teardown do
      ExportCheckpoint.clear!
      Rails.cache = @previous_cache
      DailyArchive.reset_store!
    end

    test "exports daily observations into shards" do
      result = Exporter.new(store: @store).perform(time_series_ids: [ @series.id ])
      assert_equal 1, result[:series]
      assert_operator result[:points], :>=, 2
      assert DailyArchiveShard.exists?(time_series_id: @series.id, year: Date.current.year)
      assert_nil ExportCheckpoint.read_raw
    end

    test "only_cold skips hot tip days" do
      result = Exporter.new(store: @store).perform(time_series_ids: [ @series.id ], only_cold: true)
      assert_equal 1, result[:series]
      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: 3.years.ago.to_date,
        end_on: Date.current
      )
      refute_includes points.map { |p| p[:t] }, Date.current.iso8601
      assert_includes points.map { |p| p[:t] }, 20.months.ago.to_date.iso8601
    end

    test "resumes after the last completed series" do
      other = create(:time_series)
      DailyObservation.create!(time_series: other, observed_on: 10.months.ago.to_date, value: 3.0)
      first, second = [ @series, other ].sort_by(&:id)

      checkpoint = ExportCheckpoint.start!(
        ExportCheckpoint.fingerprint_for(only_cold: false, time_series_ids: [ first.id, second.id ])
      )
      Writer.new(store: @store).upsert_from_daily_observations(
        time_series_id: first.id,
        relation: first.daily_observations
      )
      checkpoint.mark_series!(first.id, exported_points: first.daily_observations.count, exported_series: 1)

      io = StringIO.new
      progress = SyncProgress.new("ExportResume", io: io, logger: nil, every: 1)
      result = Exporter.new(store: @store, progress: progress).perform(
        time_series_ids: [ first.id, second.id ]
      )

      assert_match(/resuming export after_series_id=#{first.id}/, io.string)
      assert_equal 2, result[:series]
      assert DailyArchiveShard.exists?(time_series_id: second.id)
      assert_nil ExportCheckpoint.read_raw
    end
  end
end
