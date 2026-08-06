// Formats monitoring gauge readings for display.
// Fractional values pad to `precision` places (541.1 → "541.10").
// Whole numbers omit a trailing decimal (540 → "540").
export function formatGaugeValue(value, precision = 2) {
  if (value == null || Number.isNaN(Number(value))) return null

  const digits = Number(precision)
  const fixed = Number(value).toFixed(digits)
  const numeric = Number(fixed)

  if (digits <= 0 || Number.isInteger(numeric)) {
    return Math.round(numeric).toLocaleString("en-US")
  }

  return numeric.toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits
  })
}
