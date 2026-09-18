require "test_helper"

class UsaceHistoryIngestionTest < ActiveSupport::TestCase
  setup do
    @entry = Usace::ProjectCatalog.find_by_site_number("usacenabraystown")
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    ENV["DAILY_ARCHIVE_READS"] = "1"
    ENV["DAILY_ARCHIVE_DUAL_WRITE"] = "1"
    AppConfig.bust!

    tip_client = Object.new
    def tip_client.each_timeseries_value(**_kwargs)
      yield Time.utc(2026, 9, 16, 7, 0, 0), 786.33, 0
    end
    UsaceProjectSync.new(client: tip_client).perform(entries: [ @entry ])
    @location = MonitoringLocation.find_by!(site_number: "usacenabraystown")
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
    def history_client.each_timeseries_value(**_kwargs)
      [
        [ Time.utc(2026, 9, 10, 4, 0, 0), 786.5, 0 ],
        [ Time.utc(2026, 9, 11, 4, 0, 0), 786.4, 0 ],
        [ Time.utc(2026, 9, 16, 4, 0, 0), 786.33, 0 ]
      ].each { |t, v, q| yield t, v, q }
    end

    UsaceHistoryIngestion.new(client: history_client).perform(@location, years: 1)

    payload = HydrographSeries.for(location: @location.reload, kind: "water_level", range: "30d")
    assert_equal "daily", payload[:grain]
    assert_operator payload[:points].size, :>=, 3
    assert_in_delta 786.33, payload[:points].last[:v], 0.001
  end
end
