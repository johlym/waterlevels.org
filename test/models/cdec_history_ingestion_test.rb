require "test_helper"

class CdecHistoryIngestionTest < ActiveSupport::TestCase
  setup do
    @entry = Cdec::ReservoirCatalog.find_by_site_number("cdecoro")
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    ENV["DAILY_ARCHIVE_READS"] = "1"
    ENV["DAILY_ARCHIVE_DUAL_WRITE"] = "1"
    AppConfig.bust!

    tip_client = Object.new
    def tip_client.each_reading(**_kwargs)
      [
        { "date" => "2026-9-10 00:00", "value" => 775.0 },
        { "date" => "2026-9-11 00:00", "value" => 774.5 },
        { "date" => "2026-9-17 00:00", "value" => 770.3 },
        { "date" => "2026-9-18 00:00", "value" => -9999 }
      ].each { |row| yield row }
    end
    CdecReservoirSync.new(client: tip_client).perform(entries: [ @entry ])
    @location = MonitoringLocation.find_by!(site_number: "cdecoro")
    @client = tip_client
  end

  teardown do
    DailyArchive.reset_store!
    ENV.delete("DAILY_ARCHIVE_READS")
    ENV.delete("DAILY_ARCHIVE_DUAL_WRITE")
    AppConfig.bust!
  end

  test "history writes dailies to archive and skips missing values" do
    assert DailyArchive.archive_writes_enabled?

    CdecHistoryIngestion.new(client: @client).perform(@location, years: 1)

    payload = HydrographSeries.for(location: @location.reload, kind: "water_level", range: "30d")
    assert_equal "daily", payload[:grain]
    assert_operator payload[:points].size, :>=, 3
    assert_in_delta 770.3, payload[:points].last[:v], 0.001
    assert payload[:points].none? { |point| point[:v].to_f <= -999 }
  end
end
