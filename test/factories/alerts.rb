# frozen_string_literal: true

FactoryBot.define do
  factory :subscriber do
    sequence(:email) { |n| "alerts-user-#{n}@example.com" }
    verified_at { Time.current }
    time_zone { "America/New_York" }
    digest_hour { 7 }
    digest_minute { 0 }
    digest_enabled { true }
  end

  factory :station_watch do
    subscriber
    monitoring_location
  end

  factory :alert_rule do
    station_watch
    kind { "flood_category_change" }
    enabled { true }
    params { { "notify_clear" => true, "min_severity" => "action" } }
    armed { true }
  end

  factory :alert_event do
    monitoring_location
    kind { "flood_category_change" }
    occurred_at { Time.current }
    payload { { "from" => "no_flooding", "to" => "minor", "observed_at" => Time.current.iso8601 } }
    sequence(:dedupe_key) { |n| "flood-test-#{n}" }
  end

  factory :alert_delivery do
    subscriber
    mailer_action { "flood_category_change" }
    status { "queued" }
    metadata { {} }
  end
end
