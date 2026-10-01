# Current flood stage for a gauge page, from gage height versus NWS thresholds.
#
# The stored flood category is the more severe of the NWPS observed and forecast
# categories, which is what the map and Flood Alerts list use. A forecast can
# therefore say "moderate" while the river is still below every flood stage.
# Station pages ignore that stored category and classify the latest gage height.
# When the river is not in a flood stage, the page still names the lowest
# published flood-stage level.
class GaugeFloodStage
  # USGS gage height, then NWPS stage. Elevation datums are not flood stage.
  STAGE_CODES = [
    Usgs::ParameterCodes::WATER_LEVEL_PREFERENCE.first,
    Nwps::ParameterCodes::STAGE
  ].freeze
  FEET_UNITS = %w[ft feet foot].freeze
  TIER_KEYS = %w[action minor moderate major].freeze
  # Action stage is preparedness, not a flood stage. Prefer the lowest real
  # flood tier (usually minor) when saying where flooding begins.
  FLOOD_TIER_KEYS = %w[minor moderate major].freeze
  HIGHEST_FIRST = %w[major moderate minor action].freeze

  attr_reader :headline, :detail, :category, :pill_label

  def self.from_snapshot(snapshot)
    data = snapshot.to_h.with_indifferent_access
    new(stages: data[:flood_stages], measurements: data[:measurements])
  end

  def initialize(stages:, measurements: [], stage_ft: nil)
    @stages = normalize_stages(stages)
    @stage_ft = stage_ft.nil? ? stage_feet(measurements) : stage_ft
    @headline = "No flood stage data"
    @detail = nil
    @category = nil
    @pill_label = nil
    classify!
  end

  def text
    [ headline, detail ].compact.join(". ")
  end

  private

  def classify!
    return if @stages.empty?

    current = current_tier
    lowest = lowest_flood_stage

    if flood_tier?(current)
      @category = current
      @headline = Nwps::FloodCategories.label_for(current)
      @pill_label = @headline
      @detail = tier_level(current)
      return
    end

    if current == "action"
      @category = "action"
      @headline = "Action stage"
      @pill_label = @headline
      @detail = lowest_level(lowest) if lowest && lowest.first != "action"
      return
    end

    return unless lowest

    clause = lowest_level(lowest)
    if @stage_ft
      @category = "below"
      @headline = "Not at flood stage"
      @pill_label = @headline
      @detail = clause
    else
      @headline = clause
    end
  end

  def flood_tier?(key)
    FLOOD_TIER_KEYS.include?(key)
  end

  def current_tier
    return if @stage_ft.nil?

    HIGHEST_FIRST.each do |key|
      threshold = @stages[key]
      next if threshold.nil?
      return key if @stage_ft >= threshold
    end
    nil
  end

  def lowest_flood_stage
    key = (FLOOD_TIER_KEYS + %w[action]).find { |tier| @stages[tier] }
    return unless key

    [ key, @stages[key] ]
  end

  def tier_level(key)
    "#{key} at #{format_feet(@stages[key])} ft"
  end

  def lowest_level(tier)
    return if tier.blank?

    key, feet = tier
    "Lowest flood stage is #{key} at #{format_feet(feet)} ft"
  end

  def format_feet(feet)
    GaugeValue.format(feet, precision: 2)
  end

  def normalize_stages(stages)
    raw = stages.respond_to?(:to_h) ? stages.to_h.with_indifferent_access : {}
    TIER_KEYS.each_with_object({}) do |key, memo|
      value = raw[key]
      next if value.nil?

      feet = value.to_f
      next unless feet.positive?

      memo[key] = feet
    end
  end

  def stage_feet(measurements)
    Array(measurements).each do |measurement|
      row = measurement.to_h.with_indifferent_access
      next unless STAGE_CODES.include?(row[:parameter_code].to_s)
      next unless feet?(row[:unit])
      next if row[:value].nil?

      return row[:value].to_f
    end
    nil
  end

  def feet?(unit)
    FEET_UNITS.include?(unit.to_s.strip.downcase)
  end
end
