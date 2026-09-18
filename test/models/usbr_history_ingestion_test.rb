require "test_helper"

class UsbrHistoryIngestionTest < ActiveSupport::TestCase
  setup do
    @entry = Usbr::ReservoirCatalog.active_entries.first
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    ENV["DAILY_ARCHIVE_READS"] = "1"
    ENV["DAILY_ARCHIVE_DUAL_WRITE"] = "1"
    AppConfig.bust!

    tip_client = Object.new
    def tip_client.each_result(_item_id, items_per_page: 1, **_kwargs)
      yield(
        "dateTime" => "2026-09-16T07:00:00Z",
        "result" => 1038.5,
        "status" => "Provisional"
      )
    end
    UsbrReservoirSync.new(client: tip_client).perform(entries: [ @entry ])
    @location = MonitoringLocation.find_by!(site_number: "usbr3514")
  end

  teardown do
    DailyArchive.reset_store!
    ENV.delete("DAILY_ARCHIVE_READS")
    ENV.delete("DAILY_ARCHIVE_DUAL_WRITE")
    AppConfig.bust!
  end

  test "history writes dailies to archive and hydrograph reads them" do
    assert DailyArchive.archive_writes_enabled?

    history_client = Object.new
    def history_client.each_result(_item_id, after: nil, before: nil, items_per_page: nil)
      [
        { "dateTime" => "2026-09-10T07:00:00Z", "result" => 1039.0 },
        { "dateTime" => "2026-09-11T07:00:00Z", "result" => 1038.8 },
        { "dateTime" => "2026-09-16T07:00:00Z", "result" => 1038.5 }
      ].each { |row| yield row }
    end

    UsbrHistoryIngestion.new(client: history_client).perform(@location, years: 1)

    payload = HydrographSeries.for(location: @location.reload, kind: "water_level", range: "30d")
    assert_equal "daily", payload[:grain]
    assert_operator payload[:points].size, :>=, 3
    assert_in_delta 1038.5, payload[:points].last[:v], 0.001
  end
end
