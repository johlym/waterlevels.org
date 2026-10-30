# Durable named counters / last-known snapshots for the /admin dashboard.
# Job finishes and inventory aggregates upsert here so multi-dyno workers share
# state without Redis TTLs or process-local fallbacks.
class AdminCounter < ApplicationRecord
  SOURCES = %w[job schedule].freeze

  validates :name, presence: true, uniqueness: true
  validates :value, presence: true
  validates :computed_at, presence: true
  validates :source, inclusion: { in: SOURCES }

  class << self
    def set!(name, value: 0, source: "job", computed_at: Time.current, **payload)
      key = name.to_s
      row = rows_by_name[key]
      unless row
        row = new(name: key)
        rows_by_name[key] = row
      end
      row.assign_attributes(
        value: value.to_i,
        payload: stringify_payload(payload),
        source: source.to_s,
        computed_at: computed_at
      )
      row.save!
      row
    end

    def fetch(name)
      rows_by_name[name.to_s]
    end

    # The counters table is tiny. Load it once per request/job instead of
    # find_by per dashboard tile (fetch + payload_for used to hit the same row).
    def bust_request_cache!
      Thread.current[:admin_counter_rows_loaded] = false
      Thread.current[:admin_counter_rows] = nil
    end

    # Symbol-keyed payload hash, or nil when the counter row is missing.
    def payload_for(name)
      row = fetch(name)
      return unless row

      symbolize_payload(row.payload)
    end

    def value_for(name)
      fetch(name)&.value
    end

    def computed_at_for(name)
      fetch(name)&.computed_at
    end

    def clear!(*names)
      scope = names.flatten.compact.map(&:to_s)
      return 0 if scope.empty?

      deleted = where(name: scope).delete_all
      if Thread.current[:admin_counter_rows_loaded]
        scope.each { |key| Thread.current[:admin_counter_rows].delete(key) }
      end
      deleted
    end

    private

    def rows_by_name
      return Thread.current[:admin_counter_rows] if Thread.current[:admin_counter_rows_loaded]

      Thread.current[:admin_counter_rows] = all.index_by(&:name)
      Thread.current[:admin_counter_rows_loaded] = true
      Thread.current[:admin_counter_rows]
    end

    def stringify_payload(payload)
      JSON.parse(payload.deep_stringify_keys.to_json)
    end

    def symbolize_payload(payload)
      JSON.parse(payload.to_json, symbolize_names: true)
    end
  end
end
