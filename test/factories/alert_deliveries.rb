# frozen_string_literal: true

FactoryBot.define do
  factory :alert_delivery do
    association :subscriber, factory: [ :subscriber, :verified ]
    association :alert_event
    mailer_action { "flood_category_change" }
    status { "queued" }
    metadata { {} }

    trait :sent do
      status { "sent" }
      sent_at { Time.current }
    end
  end
end
