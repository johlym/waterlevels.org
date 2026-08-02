import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

export default class extends Controller {
  static targets = ["canvas", "history", "rangeButton"]
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

  disconnect() {
    this.destroyChart()
    this.unbindHistoryAccordion()
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
    // Avoid `this.data` — Stimulus Controllers expose a read-only `data` getter.
    this.series = await response.json()
    this.render()
  }

  render() {
    if (!this.series) return
    const points = this.series.points || []
    this.renderHistory(points)
    this.renderChart(points)
  }

  renderHistory(points) {
    if (!this.hasHistoryTarget) return
    this.unbindHistoryAccordion()

    if (!points.length) {
      this.historyTarget.innerHTML = `<p class="bg-white px-4 py-8 text-center text-base text-rolling-stone-600 dark:bg-rolling-stone-950 dark:text-rolling-stone-400 sm:px-6 sm:text-sm">No observations for this range yet.</p>`
      return
    }

    const days = this.groupPointsByDay(points)
    this.historyTarget.innerHTML = days.map((day) => {
      const rows = day.points.map((p) => `
        <tr>
          <td class="whitespace-nowrap px-4 py-3 text-rolling-stone-700 dark:text-rolling-stone-300 sm:px-6">${this.formatTime(p.t)}</td>
          <td class="whitespace-nowrap px-4 py-3 font-medium text-rolling-stone-950 tabular-nums dark:text-white sm:px-6">${this.displayValue(p.v)}</td>
        </tr>
      `).join("")

      return `
        <details class="group bg-white dark:bg-rolling-stone-950" data-day-key="${day.key}">
          <summary class="flex cursor-pointer list-none items-center gap-3 px-4 py-3 text-base marker:content-none [&::-webkit-details-marker]:hidden hover:bg-rolling-stone-50 dark:hover:bg-white/5 sm:px-6 sm:text-sm">
            <svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-5 shrink-0 text-rolling-stone-400 transition group-open:rotate-180 dark:text-rolling-stone-500">
              <path fill-rule="evenodd" d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
            </svg>
            <span class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
              <span class="font-medium text-rolling-stone-950 dark:text-white">${day.label}</span>
              <span class="text-rolling-stone-600 dark:text-rolling-stone-400">${day.points.length} ${day.points.length === 1 ? "reading" : "readings"}</span>
            </span>
          </summary>
          <div class="overflow-x-auto border-t border-rolling-stone-950/5 dark:border-white/5">
            <table class="min-w-full text-left text-base sm:text-sm">
              <thead class="bg-rolling-stone-50 dark:bg-white/5">
                <tr>
                  <th class="px-4 py-3 font-medium text-rolling-stone-600 dark:text-rolling-stone-300 sm:px-6">Time</th>
                  <th class="px-4 py-3 font-medium text-rolling-stone-600 dark:text-rolling-stone-300 sm:px-6">Value</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-rolling-stone-950/5 dark:divide-white/5">${rows}</tbody>
            </table>
          </div>
        </details>
      `
    }).join("")

    this.bindHistoryAccordion()
  }

  groupPointsByDay(points) {
    const groups = new Map()

    points.forEach((point) => {
      const date = new Date(point.t)
      if (Number.isNaN(date.getTime())) return
      const key = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`
      if (!groups.has(key)) {
        groups.set(key, {
          key,
          label: date.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric" }),
          sort: date.setHours(0, 0, 0, 0),
          points: []
        })
      }
      groups.get(key).points.push(point)
    })

    return Array.from(groups.values())
      .sort((a, b) => b.sort - a.sort)
      .map((day) => ({
        ...day,
        points: day.points.slice().sort((a, b) => new Date(b.t) - new Date(a.t))
      }))
  }

  bindHistoryAccordion() {
    this.historyToggleHandler = (event) => {
      const details = event.target
      if (!(details instanceof HTMLDetailsElement) || !details.open) return
      this.historyTarget.querySelectorAll("details[open]").forEach((other) => {
        if (other !== details) other.open = false
      })
    }
    this.historyTarget.addEventListener("toggle", this.historyToggleHandler, true)
  }

  unbindHistoryAccordion() {
    if (!this.historyToggleHandler || !this.hasHistoryTarget) return
    this.historyTarget.removeEventListener("toggle", this.historyToggleHandler, true)
    this.historyToggleHandler = null
  }

  renderChart(points) {
    if (!this.hasCanvasTarget) return

    this.destroyChart()

    const labels = points.map((p) => this.formatTimestamp(p.t))
    const values = points.map((p) => p.v)
    const chartLabel = this.series.label || this.series.kind
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches
    const grid = dark ? "rgba(255,255,255,0.08)" : "rgba(24, 24, 27, 0.08)"
    const tick = dark ? "#a1a1aa" : "#52525b"

    try {
      this.chart = new Chart(this.canvasTarget.getContext("2d"), {
        type: "line",
        data: {
          labels,
          datasets: [{
            label: chartLabel,
            data: values,
            borderColor: "#2f4ea8",
            backgroundColor: "rgba(47, 78, 168, 0.10)",
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
              bodyColor: dark ? "#d4d4d8" : "#3f3f46",
              borderColor: dark ? "rgba(255,255,255,0.12)" : "rgba(24,24,27,0.1)",
              borderWidth: 1,
              callbacks: {
                label: (context) => {
                  const raw = context.parsed.y
                  return `${chartLabel}: ${this.displayValue(raw)}`
                }
              }
            }
          },
          scales: {
            x: {
              display: true,
              border: { display: false },
              grid: { color: grid },
              ticks: {
                color: tick,
                maxTicksLimit: 4,
                maxRotation: 0,
                autoSkip: true
              }
            },
            y: {
              display: true,
              border: { display: false },
              grid: { color: grid },
              ticks: {
                color: tick,
                callback: (value) => this.displayValue(value)
              }
            }
          }
        }
      })
    } catch (error) {
      console.error("Hydrograph chart failed to render", error)
    }
  }

  destroyChart() {
    if (!this.chart) return
    this.chart.destroy()
    this.chart = null
  }

  formatTimestamp(value) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    const day = date.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" })
    return `${day} at ${this.formatTime(value)}`
  }

  formatTime(value) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    return date.toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: true
    })
  }

  displayValue(value) {
    if (value == null || Number.isNaN(value)) return "—"
    if (this.series?.kind !== "temperature") return value
    const unit = this.tempUnit()
    const converted = unit === "c" ? value : (value * 9) / 5 + 32
    return `${converted.toFixed(1)} °${unit.toUpperCase()}`
  }

  tempUnit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }
}
