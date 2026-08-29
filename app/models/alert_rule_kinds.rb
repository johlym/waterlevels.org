# frozen_string_literal: true

module AlertRuleKinds
  V1 = %w[flood_category_change threshold digest].freeze
  PHASE_F = %w[rate_of_rise in_range quiet_station approaching_stage].freeze
  ALL = (V1 + PHASE_F).freeze

  module_function

  def v1?(kind)
    V1.include?(kind.to_s)
  end

  def known?(kind)
    ALL.include?(kind.to_s)
  end
end
