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
      row = find_or_initialize_by(name: name.to_s)
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
      find_by(name: name.to_s)
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

      where(name: scope).delete_all
    end

    private

    def stringify_payload(payload)
      JSON.parse(payload.deep_stringify_keys.to_json)
    end

    def symbolize_payload(payload)
      JSON.parse(payload.to_json, symbolize_names: true)
    end
  end
end
