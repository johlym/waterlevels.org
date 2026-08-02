import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

export default class extends Controller {
  static targets = ["canvas", "tableBody", "rangeButton"]
  static values = { url: String, measurements: Array }

  connect() {
    const first = (this.measurementsValue || [])[0] || {}
    this.kind = first.kind
    this.parameterCode = first.parameter_code
    this.range = "7d"
    this.load()
    this.element.addEventListener("parameter-toggle:changed", (event) => {
      this.kind = event.detail.kind
      this.parameterCode = event.detail.parameterCode
      this.load()
    })
    this.element.addEventListener("temperature-unit:changed", () => this.render())
  }

  setRange(event) {
    this.range = event.params.range
    this.rangeButtonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", button.dataset.hydrographRangeParam === this.range ? "true" : "false")
    })
    this.load()
  }

  async load() {
    if (!this.parameterCode && !this.kind) return
    const params = new URLSearchParams({ range: this.range })
    if (this.parameterCode) params.set("parameter_code", this.parameterCode)
    if (this.kind) params.set("kind", this.kind)
    const url = `${this.urlValue}?${params.toString()}`
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
    const chartLabel = this.data.label || this.data.kind
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches
    const grid = dark ? "rgba(255,255,255,0.06)" : "rgba(15,23,42,0.06)"
    const tick = dark ? "#a1a1aa" : "#71717a"

    if (this.chart) this.chart.destroy()
    this.chart = new Chart(this.canvasTarget.getContext("2d"), {
      type: "line",
      data: {
        labels,
        datasets: [{
          label: chartLabel,
          data: values,
          borderColor: "#2f4ea8",
          backgroundColor: "rgba(47, 78, 168, 0.08)",
          fill: true,
          tension: 0.25,
          pointRadius: 0,
          borderWidth: 2
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: dark ? "#18181b" : "#ffffff",
            titleColor: dark ? "#fafafa" : "#18181b",
            bodyColor: dark ? "#d4d4d8" : "#52525b",
            borderColor: dark ? "rgba(255,255,255,0.1)" : "rgba(15,23,42,0.08)",
            borderWidth: 1
          }
        },
        scales: {
          x: {
            display: true,
            grid: { color: grid, drawBorder: false },
            ticks: { color: tick, maxTicksLimit: 6 }
          },
          y: {
            display: true,
            grid: { color: grid, drawBorder: false },
            ticks: { color: tick }
          }
        }
      }
    })

    if (this.hasTableBodyTarget) {
      if (!points.length) {
        this.tableBodyTarget.innerHTML = `<tr><td colspan="2" class="px-4 py-8 text-center text-rolling-stone-500 dark:text-rolling-stone-400 sm:px-6">No observations for this range yet.</td></tr>`
        return
      }

      this.tableBodyTarget.innerHTML = points.slice().reverse().slice(0, 100).map((p) => {
        return `<tr>
          <td class="whitespace-nowrap px-4 py-3 text-rolling-stone-600 dark:text-rolling-stone-300 sm:px-6">${p.t}</td>
          <td class="whitespace-nowrap px-4 py-3 font-medium text-rolling-stone-950 tabular-nums dark:text-white sm:px-6">${this.displayValue(p.v)}</td>
        </tr>`
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
