# frozen_string_literal: true

# Watch nearby stations for a corridor-style subscription (Phase F).
module Alerts
  class CorridorWatch
    DEFAULT_LIMIT = 5

    def self.add_nearby!(subscriber:, origin:, limit: DEFAULT_LIMIT)
      new(subscriber: subscriber, origin: origin, limit: limit).add_nearby!
    end

    def initialize(subscriber:, origin:, limit:)
      @subscriber = subscriber
      @origin = origin
      @limit = limit
    end

    def add_nearby!
      ids = Array(@origin.nearby_station_ids).first(@limit)
      created = []
      MonitoringLocation.where(id: ids).find_each do |location|
        watch = @subscriber.station_watches.find_or_create_by!(monitoring_location: location)
        watch.ensure_default_rules!
        created << watch
      end
      created
    end
  end
end
