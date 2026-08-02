import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

export default class extends Controller {
  static targets = ["canvas", "tableBody"]
  static values = { url: String, kinds: Array }

  connect() {
    this.kind = (this.kindsValue || [])[0]
    this.range = "7d"
    this.load()
    this.element.addEventListener("parameter-toggle:changed", (event) => {
      this.kind = event.detail.kind
      this.load()
    })
    this.element.addEventListener("temperature-unit:changed", () => this.render())
  }

  setRange(event) {
    this.range = event.params.range
    this.load()
  }

  async load() {
    if (!this.kind) return
    const url = `${this.urlValue}?kind=${encodeURIComponent(this.kind)}&range=${encodeURIComponent(this.range)}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    this.data = await response.json()
    this.render()
  }

  render() {
    if (!this.data) return
    const points = this.data.points || []
    const labels = points.map((p) => p.t)
    const values = points.map((p) => this.displayValue(p.v))

    if (this.chart) this.chart.destroy()
    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: {
        labels,
        datasets: [{
          label: this.data.kind,
          data: values,
          borderColor: "#2f4ea8",
          tension: 0.2,
          pointRadius: 0
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { x: { display: true }, y: { display: true } }
      }
    })

    if (this.hasTableBodyTarget) {
      this.tableBodyTarget.innerHTML = points.slice().reverse().slice(0, 100).map((p) => {
        return `<tr><td class="px-3 py-2">${p.t}</td><td class="px-3 py-2 tabular-nums">${this.displayValue(p.v)}</td></tr>`
      }).join("")
    }
  }

  displayValue(value) {
    if (this.data.kind !== "temperature") return value
    const unit = this.tempUnit()
    const converted = unit === "c" ? value : (value * 9) / 5 + 32
    return `${converted.toFixed(1)} °${unit.toUpperCase()}`
  }

  tempUnit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }
}
