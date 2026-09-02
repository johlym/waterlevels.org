# frozen_string_literal: true

require "test_helper"

module Alerts
  class WatchedLocationsTest < ActiveSupport::TestCase
    setup do
      WatchedLocations.reset!
      @location = create(:monitoring_location)
      @subscriber = create(:subscriber, :verified)
    end

    teardown do
      WatchedLocations.reset!
    end

    test "includes location with active watch" do
      create(:station_watch, subscriber: @subscriber, monitoring_location: @location)

      assert WatchedLocations.include?(@location.id)
      assert_includes WatchedLocations.location_ids, @location.id
    end

    test "excludes unwatched locations" do
      refute WatchedLocations.include?(@location.id)
    end

    test "excludes locations when subscriber is paused" do
      create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
      @subscriber.update!(paused_at: Time.current)
      WatchedLocations.reset!

      refute WatchedLocations.include?(@location.id)
    end

    test "resets cache when watch is created or destroyed" do
      watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
      WatchedLocations.location_ids
      watch.destroy!

      refute WatchedLocations.include?(@location.id)
    end
  end
end
