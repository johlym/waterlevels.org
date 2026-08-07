require "test_helper"

module DailyArchive
  class WriterReaderTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @series = create(:time_series)
    end

    teardown do
      DailyArchive.reset_store!
    end

    test "writer upserts year shard and reader returns range" do
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [
          { "d" => "2023-06-01", "v" => 1.0, "s" => "usgs" },
          { "d" => "2023-06-02", "v" => 2.0, "s" => "usgs" },
          { "d" => "2024-01-15", "v" => 3.0, "s" => "derived" }
        ]
      )

      shard = DailyArchiveShard.find_by!(time_series_id: @series.id, year: 2023)
      assert_equal 2, shard.point_count
      assert_equal "usgs", shard.source_mix
      assert @store.keys.any? { |k| k.include?("/#{@series.id}/2023.json.gz") }

      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: Date.new(2023, 6, 1),
        end_on: Date.new(2023, 6, 30)
      )
      assert_equal [ "2023-06-01", "2023-06-02" ], points.map { |p| p[:t] }
      assert_equal 1.0, points.first[:v]
    end

    test "usgs overwrites derived on re-upsert" do
      writer = Writer.new(store: @store)
      writer.upsert(
        time_series_id: @series.id,
        points: [ { "d" => "2022-03-01", "v" => 1.0, "s" => "derived" } ]
      )
      writer.upsert(
        time_series_id: @series.id,
        points: [ { "d" => "2022-03-01", "v" => 4.5, "s" => "usgs", "a" => "Approved" } ]
      )

      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: Date.new(2022, 3, 1),
        end_on: Date.new(2022, 3, 1)
      )
      assert_equal 4.5, points.first[:v]
      assert_equal "usgs", DailyArchiveShard.find_by!(time_series_id: @series.id, year: 2022).source_mix
    end
  end
end
