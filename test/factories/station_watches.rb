# frozen_string_literal: true

FactoryBot.define do
  factory :station_watch do
    association :subscriber, factory: [ :subscriber, :verified ]
    association :monitoring_location
    label { nil }
  end
end
