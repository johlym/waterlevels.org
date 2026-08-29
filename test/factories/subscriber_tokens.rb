# frozen_string_literal: true

FactoryBot.define do
  factory :subscriber_token do
    association :subscriber, factory: [ :subscriber, :verified ]
    purpose { "manage" }
    token_digest { SubscriberToken.digest(SecureRandom.urlsafe_base64(32)) }
    expires_at { 2.years.from_now }

    trait :verify do
      purpose { "verify" }
      expires_at { 48.hours.from_now }
    end

    trait :unsubscribe do
      purpose { "unsubscribe" }
      expires_at { 30.days.from_now }
    end

    trait :used do
      used_at { Time.current }
    end
  end
end
