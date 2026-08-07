require "test_helper"

module DailyArchive
  class ExporterTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @series = create(:time_series)
      DailyObservation.create!(time_series: @series, observed_on: 20.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 2.0)
    end

    teardown do
      DailyArchive.reset_store!
    end

    test "exports daily observations into shards" do
      result = Exporter.new(store: @store).perform(time_series_ids: [ @series.id ])
      assert_equal 1, result[:series]
      assert_operator result[:points], :>=, 2
      assert DailyArchiveShard.exists?(time_series_id: @series.id, year: Date.current.year)
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
  end
end
