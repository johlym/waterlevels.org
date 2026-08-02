FactoryBot.define do
  factory :monitoring_location do
    sequence(:site_number) { |n| format("%08d", n) }
    usgs_monitoring_location_id { "USGS-#{site_number}" }
    name { "Example River near Town" }
    slug { "example-river-near-town" }
    latitude { 47.5 }
    longitude { -121.8 }
    state_code { "wa" }
    state_name { "Washington" }
    county_name { "King" }
    has_water_level { true }
    has_discharge { true }
    has_temperature { false }
    latest_observed_at { 1.hour.ago }
  end
end
