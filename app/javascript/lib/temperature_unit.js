// Temperature is stored/served in °C. Convert for display from the
// temperature_unit cookie ("f" default, or "c").

export function preferredTemperatureUnit(cookieString = "") {
  const match = String(cookieString).match(/(?:^|; )temperature_unit=([^;]*)/)
  return match && match[1] === "c" ? "c" : "f"
}

/** Absolute temperature: °C → preferred unit (adds 32 for Fahrenheit). */
export function convertTemperatureC(celsius, unit) {
  const c = Number(celsius)
  if (Number.isNaN(c)) return null
  return unit === "c" ? c : (c * 9) / 5 + 32
}

/** Temperature delta: scale only (do not add 32). */
export function convertTemperatureDeltaC(deltaC, unit) {
  const c = Number(deltaC)
  if (Number.isNaN(c)) return null
  return unit === "c" ? c : (c * 9) / 5
}

export function formatTemperature(value, { signed = false } = {}) {
  if (value == null || Number.isNaN(value)) return null
  const formatted = value.toLocaleString("en-US", {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1
  })
  if (signed && value > 0) return `+${formatted}`
  return formatted
}

export function temperatureUnitLabel(unit) {
  return `°${unit === "c" ? "C" : "F"}`
}
