# frozen_string_literal: true

# Cached set of monitoring_location ids with at least one active station watch.
# Used to skip AlertEvaluation enqueue for the ~99% of stations nobody watches.
module Alerts
  module WatchedLocations
    CACHE_KEY = "alerts:watched_location_ids_v1"
    TTL = 5.minutes

    module_function

    def include?(location_id)
      location_ids.include?(location_id.to_i)
    end

    def location_ids
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL) do
        StationWatch.joins(:subscriber)
          .merge(Subscriber.active)
          .distinct
          .pluck(:monitoring_location_id)
      end
    end

    def reset!
      Rails.cache.delete(CACHE_KEY)
    end
  end
end
