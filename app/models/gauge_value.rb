# Formats monitoring gauge readings for display.
#
# Fractional values are padded to +precision+ places (541.1 → "541.10").
# Whole numbers omit a trailing decimal (540 → "540"). Discharge-style
# precision 0 always renders as an integer.
module GaugeValue
  module_function

  def format(value, precision: 2, delimiter: ",")
    return if value.nil?

    precision = precision.to_i
    rounded = BigDecimal(value.to_s).round(precision)

    if precision <= 0 || rounded == rounded.to_i
      ActiveSupport::NumberHelper.number_to_delimited(rounded.to_i, delimiter: delimiter)
    else
      ActiveSupport::NumberHelper.number_to_rounded(
        rounded,
        precision: precision,
        delimiter: delimiter,
        strip_insignificant_zeros: false
      )
    end
  end
end
