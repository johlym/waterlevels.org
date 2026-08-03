FactoryBot.define do
  factory :monitoring_location do
    # Random IDs avoid collisions with hardcoded site numbers in other tests
    # under parallel runs (FactoryBot sequences are per-worker and predictable).
    site_number do
      loop do
        candidate = format("%08d", SecureRandom.random_number(100_000_000))
        break candidate unless MonitoringLocation.exists?(site_number: candidate)
      end
    end
    usgs_monitoring_location_id { "USGS-#{site_number}" }
    name { "Example River near Town" }
    slug { "example-river-near-town" }
    latitude { 47.5 }
    longitude { -121.8 }
    state_code { "wa" }
    state_name { "Washington" }
    county_name { "King" }
    time_zone { "PST" }
    has_water_level { true }
    has_discharge { true }
    has_temperature { false }
    latest_observed_at { 1.hour.ago }
  end
end
