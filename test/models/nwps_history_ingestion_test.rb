require "test_helper"

class NwpsHistoryIngestionTest < ActiveSupport::TestCase
  setup do
    @entry = Nwps::GaugeCatalog.find_by_site_number("nwpsacrw1")
    tip_client = Object.new
    def tip_client.gauge(_lid)
      {
        "lid" => "ACRW1",
        "usgsId" => "",
        "status" => {
          "observed" => {
            "primary" => 1.3,
            "floodCategory" => "no_flooding",
            "validTime" => "2026-09-18T03:15:00Z"
          },
          "forecast" => {}
        },
        "flood" => { "categories" => {} }
      }
    end
    def tip_client.stageflow(_lid)
      {
        "observed" => {
          "data" => [
            { "validTime" => "2026-09-16T03:15:00Z", "primary" => 1.2 },
            { "validTime" => "2026-09-17T03:15:00Z", "primary" => 1.25 },
            { "validTime" => "2026-09-18T03:15:00Z", "primary" => 1.3 },
            { "validTime" => "2026-09-18T02:00:00Z", "primary" => -999 }
          ]
        }
      }
    end

    NwpsGaugeSync.new(client: tip_client).perform(entries: [ @entry ])
    @location = MonitoringLocation.find_by!(site_number: "nwpsacrw1")
    @client = tip_client
  end

  test "history writes continuous points and hydrograph reads them" do
    NwpsHistoryIngestion.new(client: @client).perform(@location)

    series = @location.time_series.sole
    assert_equal 3, series.continuous_observations.count
    assert series.continuous_newest_at.present?
    assert_not @location.reload.daily_only?

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "7d")
    assert_equal "continuous", payload[:grain]
    assert_operator payload[:points].size, :>=, 3
    assert_in_delta 1.3, payload[:points].last[:v], 0.001
  end
end
