module UnitLabel
  # USGS and local strings often use "ft3/s" or "ft^3/s"; present as ft³/s.
  def self.format(unit)
    return if unit.nil?

    unit.to_s.gsub(/ft\^?3/i, "ft³")
  end
end
