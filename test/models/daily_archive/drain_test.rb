require "test_helper"

module DailyArchive
  class DrainTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      AppConfig.bust!
      @series = create(:time_series)
      @day = Date.current - 1
    end

    teardown do
      Rails.cache = @previous_cache
      DailyArchive.reset_store!
      ENV.delete("DAILY_ARCHIVE_PRUNE")
      AppConfig.bust!
    end

    test "no-ops when prune is disabled" do
      DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => @day.iso8601, "v" => 3.0, "s" => "usgs" } ]
      )

      result = Drain.new(store: @store).perform
      assert_equal 0, result[:deleted]
      assert DailyObservation.exists?(time_series_id: @series.id, observed_on: @day)
    end

    test "deletes leftover postgres dailies already present in the archive" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => @day.iso8601, "v" => 3.0, "s" => "usgs" } ]
      )

      result = Drain.new(store: @store).perform
      assert_equal 1, result[:deleted]
      assert_equal 0, result[:blocked]
      assert_nil DailyObservation.find_by(time_series_id: @series.id, observed_on: @day)
    end

    test "keeps official USGS leftover when the archive only has a derived mean" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      DailyObservation.create!(time_series: @series, observed_on: @day, value: 12.0)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => @day.iso8601, "v" => 8.0, "s" => "derived" } ]
      )

      result = Drain.new(store: @store).perform
      assert_equal 0, result[:deleted]
      assert_equal 1, result[:blocked]
      leftover = DailyObservation.find_by!(time_series_id: @series.id, observed_on: @day)
      assert_in_delta 12.0, leftover.value, 0.01
    end

    test "deletes derived leftover when the archive already has that day" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      DailyObservation.create!(
        time_series: @series,
        observed_on: @day,
        value: 8.0,
        qualifier: "derived_continuous"
      )
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => @day.iso8601, "v" => 8.0, "s" => "derived" } ]
      )

      result = Drain.new(store: @store).perform
      assert_equal 1, result[:deleted]
      assert_equal 0, result[:blocked]
      assert_nil DailyObservation.find_by(time_series_id: @series.id, observed_on: @day)
    end

    test "counts days still only in postgres as blocked" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)

      result = Drain.new(store: @store).perform
      assert_equal 0, result[:deleted]
      assert_equal 1, result[:blocked]
      assert DailyObservation.exists?(time_series_id: @series.id, observed_on: @day)
    end

    test "delete_exported! removes the same relation when prune is on" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)
      relation = @series.daily_observations.where("observed_on < ?", Date.current)

      assert_equal 1, Drain.new(store: @store).delete_exported!(relation)
      assert_equal 0, @series.daily_observations.count
    end

    test "resumes after a series cursor" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      AppConfig.bust!
      other = create(:time_series)
      first, second = [ @series, other ].sort_by(&:id)
      [ first, second ].each do |series|
        DailyObservation.create!(time_series: series, observed_on: @day, value: 3.0)
        Writer.new(store: @store).upsert(
          time_series_id: series.id,
          points: [ { "d" => @day.iso8601, "v" => 3.0, "s" => "usgs" } ]
        )
      end

      result = Drain.new(store: @store).perform(after_series_id: first.id)
      assert_equal 1, result[:deleted]
      assert DailyObservation.exists?(time_series_id: first.id, observed_on: @day)
      assert_nil DailyObservation.find_by(time_series_id: second.id, observed_on: @day)
    end
  end
end
