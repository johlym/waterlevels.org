# frozen_string_literal: true

FactoryBot.define do
  factory :alert_event do
    association :monitoring_location
    kind { "flood_category_change" }
    occurred_at { Time.current }
    payload { { "from" => "no_flooding", "to" => "action" } }
    sequence(:dedupe_key) { |n| "flood-#{n}-#{SecureRandom.hex(4)}" }
  end
end
