# frozen_string_literal: true

FactoryBot.define do
  factory :subscriber do
    sequence(:email) { |n| "subscriber#{n}@example.com" }
    time_zone { "America/New_York" }
    digest_hour { 7 }
    digest_minute { 0 }
    digest_enabled { true }

    trait :verified do
      verified_at { Time.current }
    end

    trait :paused do
      verified_at { Time.current }
      paused_at { Time.current }
    end

    trait :unsubscribed do
      verified_at { Time.current }
      unsubscribed_at { Time.current }
      digest_enabled { false }
    end
  end
end
