import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display"]
  static values = { url: String }

  connect() {
    this.render()
  }

  setF() { this.setUnit("f") }
  setC() { this.setUnit("c") }

  async setUnit(unit) {
    document.cookie = `temperature_unit=${unit}; path=/; max-age=31536000; SameSite=Lax`
    if (this.hasUrlValue) {
      const token = document.querySelector("meta[name='csrf-token']")?.content
      await fetch(this.urlValue, {
        method: "PUT",
        headers: {
          "X-CSRF-Token": token,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ unit })
      })
    }
    this.render()
    this.element.dispatchEvent(new CustomEvent("temperature-unit:changed", { bubbles: true }))
  }

  render() {
    const unit = this.unit()
    this.displayTargets.forEach((el) => {
      const c = parseFloat(el.dataset.tempC)
      if (Number.isNaN(c)) return
      const value = unit === "c" ? c : (c * 9) / 5 + 32
      el.textContent = `${value.toFixed(1)} °${unit.toUpperCase()}`
    })
  }

  unit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }
}
