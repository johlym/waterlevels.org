# frozen_string_literal: true

FactoryBot.define do
  factory :alert_rule do
    association :station_watch
    kind { "flood_category_change" }
    enabled { true }
    params { { "notify_clear" => true, "min_severity" => "action" } }
    armed { true }

    trait :threshold do
      kind { "threshold" }
      params do
        {
          "parameter" => "water_level",
          "op" => "above",
          "value" => 10.0,
          "duration_minutes" => 30,
          "cooldown_minutes" => 360,
          "hysteresis" => 0.2
        }
      end
    end

    trait :digest do
      kind { "digest" }
      params { { "include" => true } }
    end
  end
end
