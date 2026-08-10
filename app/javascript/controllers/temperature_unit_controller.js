import { Controller } from "@hotwired/stimulus"
import {
  convertTemperatureC,
  convertTemperatureDeltaC,
  formatTemperature,
  preferredTemperatureUnit,
  temperatureUnitLabel
} from "../lib/temperature_unit"

export default class extends Controller {
  static targets = ["display", "button"]
  static values = { url: String }

  connect() {
    this.render()
  }

  setF() { this.setUnit("f") }
  setC() { this.setUnit("c") }

  async setUnit(unit) {
    document.cookie = `temperature_unit=${unit}; path=/; max-age=31536000; SameSite=Lax`
    if (this.hasUrlValue) {
      // No CSRF: public pages skip the Rails session so HTML can be edge-cached.
      await fetch(this.urlValue, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ unit })
      })
    }
    this.render()
    this.element.dispatchEvent(new CustomEvent("temperature-unit:changed", { bubbles: true }))
  }

  render() {
    const unit = this.unit()
    const unitLabel = temperatureUnitLabel(unit)

    this.buttonTargets.forEach((button) => {
      const selected = button.dataset.temperatureUnitUnitParam === unit
      button.setAttribute("aria-pressed", selected ? "true" : "false")
    })

    this.displayTargets.forEach((el) => {
      const prefix = el.dataset.tempPrefix || ""
      const hideUnit = el.dataset.tempHideUnit === "true"
      const deltaRaw = el.dataset.tempDeltaC
      const isDelta = deltaRaw !== undefined && deltaRaw !== ""

      const converted = isDelta
        ? convertTemperatureDeltaC(deltaRaw, unit)
        : convertTemperatureC(el.dataset.tempC, unit)
      if (converted == null) return

      const formatted = formatTemperature(converted, { signed: isDelta })
      if (formatted == null) return

      el.textContent = hideUnit
        ? `${prefix}${formatted}`
        : `${prefix}${formatted} ${unitLabel}`
    })
  }

  unit() {
    return preferredTemperatureUnit(document.cookie)
  }
}
