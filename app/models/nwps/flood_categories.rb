module Nwps
  module FloodCategories
    # Official NWS observed/forecast floodCategory values we surface.
    ALL = %w[no_flooding action minor moderate major].freeze
    ALERT = %w[action minor moderate major].freeze

    LABELS = {
      "no_flooding" => "Normal",
      "action" => "Action Stage",
      "minor" => "Minor Flooding",
      "moderate" => "Moderate Flooding",
      "major" => "Major Flooding"
    }.freeze

    SHORT_LABELS = {
      "no_flooding" => "Normal",
      "action" => "Action",
      "minor" => "Minor Flood",
      "moderate" => "Moderate Flood",
      "major" => "Major Flood"
    }.freeze

    module_function

    def normalize(value)
      key = value.to_s.strip.downcase
      return if key.blank?
      return key if ALL.include?(key)

      nil
    end

    def label_for(value)
      key = normalize(value)
      return if key.blank?

      LABELS[key]
    end

    def short_label_for(value)
      key = normalize(value)
      return if key.blank?

      SHORT_LABELS[key]
    end

    def alert?(value)
      ALERT.include?(normalize(value))
    end

    def stage_value(raw)
      return if raw.nil?

      value = raw.to_f
      return if value <= 0 || value == -9999.0

      value
    end
  end
end
