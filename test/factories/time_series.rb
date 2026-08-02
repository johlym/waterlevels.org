FactoryBot.define do
  factory :time_series do
    monitoring_location
    sequence(:usgs_time_series_id) { |n| "ts-#{n}" }
    parameter_code { "00065" }
    measurement_kind { "water_level" }
    primary_series { true }
    selected_for_display { true }
    unit_of_measure { "ft" }
  end
end
