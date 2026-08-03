import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

const SERIES_COLORS = {
  discharge: { border: "#22d3ee", fill: "rgba(34, 211, 238, 0.18)", legend: "bg-cyan" },
  water_level: { border: "#60a5fa", fill: "rgba(96, 165, 250, 0.12)", legend: "bg-blue" },
  temperature: { border: "#2dd4bf", fill: "rgba(45, 212, 191, 0.12)", legend: "bg-teal" }
}

const FLOOD_STAGE_COLORS = {
  action: { border: "#fbbf24", legend: "bg-flood-action" },
  minor: { border: "#fb923c", legend: "bg-flood-minor" },
  moderate: { border: "#f43f5e", legend: "bg-flood-moderate" },
  major: { border: "#ef4444", legend: "bg-flood-major" }
}

const FLOOD_STAGE_LABELS = {
  action: "Action stage",
  minor: "Minor flood",
  moderate: "Moderate flood",
  major: "Major flood"
}

const FLOOD_STAGE_ORDER = ["action", "minor", "moderate", "major"]

const PAGE_SIZE = 8

export default class extends Controller {
  static targets = ["canvas", "history", "rangeButton", "legend", "stats", "daySelect"]
  static values = {
    url: String,
    measurements: Array,
    floodStages: Object,
    timeZone: { type: String, default: "" },
    timeZoneLabel: { type: String, default: "" }
  }

  connect() {
    const first = (this.measurementsValue || [])[0] || {}
    this.kind = first.kind
    this.parameterCode = first.parameter_code
    this.range = "7d"
    this.selectedDayKey = null
    this.pageOffset = 0
    this.seriesByKey = {}
    this.load()
    this.element.addEventListener("parameter-toggle:changed", (event) => {
      this.kind = event.detail.kind
      this.parameterCode = event.detail.parameterCode
      this.render()
    })
    this.element.addEventListener("temperature-unit:changed", () => this.render())
  }

  disconnect() {
    this.destroyChart()
  }

  setRange(event) {
    this.range = event.params.range
    this.rangeButtonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", button.dataset.hydrographRangeParam === this.range ? "true" : "false")
    })
    this.selectedDayKey = null
    this.pageOffset = 0
    this.load()
  }

  selectDay() {
    if (!this.hasDaySelectTarget) return
    this.selectedDayKey = this.daySelectTarget.value
    this.pageOffset = 0
    this.renderHistory()
  }

  loadMore() {
    this.pageOffset += PAGE_SIZE
    this.renderHistory()
  }

  loadPrevious() {
    this.pageOffset = Math.max(0, this.pageOffset - PAGE_SIZE)
    this.renderHistory()
  }

  exportCsv() {
    const day = this.currentDay()
    if (!day) return

    const columns = this.tableColumns()
    const header = [this.timeColumnLabel(), ...columns.map((c) => c.header), "Status"]
    const rows = day.rows.map((row) => {
      const cells = columns.map((col) => {
        const value = row.values[col.key]
        return value == null ? "" : this.formatCellValue(value, col.kind)
      })
      return [this.formatClock(row.t), ...cells, row.status]
    })

    const csv = [header, ...rows]
      .map((line) => line.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(","))
      .join("\n")

    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = `waterlevels-${day.key}.csv`
    link.click()
    URL.revokeObjectURL(url)
  }

  async load() {
    const measurements = this.uniqueMeasurements()
    if (!measurements.length) return

    const results = await Promise.all(
      measurements.map(async (measurement) => {
        const params = new URLSearchParams({ range: this.range })
        if (measurement.parameter_code) params.set("parameter_code", measurement.parameter_code)
        if (measurement.kind) params.set("kind", measurement.kind)
        const response = await fetch(`${this.urlValue}?${params.toString()}`, {
          headers: { Accept: "application/json" }
        })
        if (!response.ok) return null
        return response.json()
      })
    )

    this.seriesByKey = {}
    results.filter(Boolean).forEach((series) => {
      const key = series.parameter_code || series.kind
      this.seriesByKey[key] = series
    })

    this.render()
  }

  render() {
    const primary = this.primarySeries()
    if (!primary) return

    this.series = primary
    this.renderLegend()
    this.renderStats(primary.points || [])
    this.renderChart()
    this.renderDaySelect()
    this.renderHistory()
  }

  uniqueMeasurements() {
    const seen = new Set()
    return (this.measurementsValue || []).filter((measurement) => {
      const key = measurement.parameter_code || measurement.kind
      if (!key || seen.has(key)) return false
      seen.add(key)
      return true
    })
  }

  primarySeries() {
    const byCode = this.parameterCode && this.seriesByKey[this.parameterCode]
    if (byCode) return byCode
    const byKind = Object.values(this.seriesByKey).find((series) => series.kind === this.kind)
    return byKind || Object.values(this.seriesByKey)[0]
  }

  companionSeries(primary) {
    if (!primary) return null
    if (primary.kind === "discharge") {
      return Object.values(this.seriesByKey).find((series) => series.kind === "water_level") || null
    }
    if (primary.kind === "water_level") {
      return Object.values(this.seriesByKey).find((series) => series.kind === "discharge") || null
    }
    return null
  }

  renderLegend() {
    if (!this.hasLegendTarget) return
    const primary = this.primarySeries()
    const companion = this.companionSeries(primary)
    const items = [primary, companion].filter(Boolean)
    const pointValues = (primary?.points || []).map((point) => point.v)
    const floodStages = primary?.kind === "water_level"
      ? this.visibleFloodStages(pointValues, this.floodStageEntries())
      : []

    if (!items.length && !floodStages.length) {
      this.legendTarget.innerHTML = ""
      return
    }

    this.legendTarget.innerHTML = `
      ${items.map((series) => {
        const colors = SERIES_COLORS[series.kind] || SERIES_COLORS.discharge
        const unit = this.unitLabel(series)
        return `
          <div class="item">
            <span class="swatch ${colors.legend}" aria-hidden="true"></span>
            <span>${this.escapeHtml(series.label || series.kind)}${unit ? ` (${this.escapeHtml(unit)})` : ""}</span>
          </div>
        `
      }).join("")}
      ${floodStages.map(({ key, value }) => {
        const colors = FLOOD_STAGE_COLORS[key]
        const label = FLOOD_STAGE_LABELS[key] || key
        return `
          <div class="item">
            <span class="swatch dashed ${colors.legend}" aria-hidden="true"></span>
            <span>${this.escapeHtml(label)} (${this.escapeHtml(this.displayValue(value, "water_level"))} ft)</span>
          </div>
        `
      }).join("")}
      <div class="hint">Hover for details</div>
    `
  }

  floodStageEntries() {
    const stages = this.floodStagesValue || {}
    return FLOOD_STAGE_ORDER.flatMap((key) => {
      const raw = stages[key]
      if (raw == null || raw === "") return []
      const value = Number(raw)
      if (!Number.isFinite(value) || value <= 0) return []
      return [{ key, value }]
    })
  }

  // Only pull flood thresholds into the Y domain when they sit near the
  // observed series. Distant major/moderate lines otherwise leave a large
  // empty band above normal gage heights.
  visibleFloodStages(pointValues, stageEntries) {
    if (!stageEntries.length) return []

    const points = pointValues.filter((value) => Number.isFinite(value))
    if (!points.length) return stageEntries

    const dataMax = Math.max(...points)
    const dataMin = Math.min(...points)
    const span = Math.max(dataMax - dataMin, Math.abs(dataMax) * 0.08, 0.25)
    const headroom = Math.max(span * 2.5, 1.5)

    const atOrBelow = stageEntries.filter((stage) => stage.value <= dataMax)
    const above = stageEntries
      .filter((stage) => stage.value > dataMax)
      .sort((a, b) => a.value - b.value)
    const nextAbove = above[0]

    const visible = [...atOrBelow]
    if (nextAbove && (nextAbove.value - dataMax) <= headroom) {
      visible.push(nextAbove)
    }
    return visible
  }

  renderStats(points) {
    if (!this.hasStatsTarget) return

    if (!points.length) {
      this.statsTarget.innerHTML = `<p class="empty">No observations for this range yet.</p>`
      return
    }

    let high = points[0]
    let low = points[0]
    let sum = 0
    points.forEach((point) => {
      if (point.v > high.v) high = point
      if (point.v < low.v) low = point
      sum += point.v
    })
    const average = sum / points.length
    const unit = this.unitLabel(this.series)

    this.statsTarget.innerHTML = `
      <div>
        <p class="label">Period high</p>
        <p class="value">${this.escapeHtml(this.displayValue(high.v, this.series.kind))} ${this.escapeHtml(unit || "")}</p>
        <p class="meta">${this.escapeHtml(this.formatTimestamp(high.t))}</p>
      </div>
      <div>
        <p class="label">Period low</p>
        <p class="value">${this.escapeHtml(this.displayValue(low.v, this.series.kind))} ${this.escapeHtml(unit || "")}</p>
        <p class="meta">${this.escapeHtml(this.formatTimestamp(low.t))}</p>
      </div>
      <div>
        <p class="label">Period average</p>
        <p class="value">${this.escapeHtml(this.displayValue(average, this.series.kind))} ${this.escapeHtml(unit || "")}</p>
        <p class="meta">Based on ${points.length} ${points.length === 1 ? "reading" : "readings"}</p>
      </div>
      <div>
        <p class="label">Historical median</p>
        <p class="value">—</p>
        <p class="meta">Not available yet</p>
      </div>
    `
  }

  renderDaySelect() {
    if (!this.hasDaySelectTarget) return
    const days = this.groupedDays()

    if (!days.length) {
      this.daySelectTarget.innerHTML = `<option value="">No days available</option>`
      this.daySelectTarget.disabled = true
      return
    }

    this.daySelectTarget.disabled = false
    if (!this.selectedDayKey || !days.some((day) => day.key === this.selectedDayKey)) {
      this.selectedDayKey = days[0].key
      this.pageOffset = 0
    }

    const now = new Date()
    const todayKey = this.dayKeyFromDate(now)
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000)
    const yesterdayKey = this.dayKeyFromDate(yesterday)

    this.daySelectTarget.innerHTML = days.map((day) => {
      const prefix = day.key === todayKey ? "Today — " : (day.key === yesterdayKey ? "Yesterday — " : "")
      return `<option value="${day.key}" ${day.key === this.selectedDayKey ? "selected" : ""}>${prefix}${day.shortLabel}</option>`
    }).join("")
  }

  dayKeyFromDate(date) {
    const { year, month, day } = this.dayParts(date)
    return `${year}-${month}-${day}`
  }

  dayParts(date) {
    const parts = new Intl.DateTimeFormat("en-US", this.localeOptions({
      year: "numeric",
      month: "2-digit",
      day: "2-digit"
    })).formatToParts(date)
    const value = (type) => parts.find((part) => part.type === type)?.value
    return { year: value("year"), month: value("month"), day: value("day") }
  }

  localeOptions(options = {}) {
    if (this.timeZoneValue) return { ...options, timeZone: this.timeZoneValue }
    return options
  }

  timeColumnLabel() {
    const label = (this.timeZoneLabelValue || "").trim()
    return label ? `Time (${label})` : "Time"
  }

  renderHistory() {
    if (!this.hasHistoryTarget) return
    const day = this.currentDay()

    if (!day) {
      this.historyTarget.innerHTML = `<p class="empty">No observations for this range yet.</p>`
      return
    }

    const columns = this.tableColumns()
    const visible = day.rows.slice(this.pageOffset, this.pageOffset + PAGE_SIZE)
    const showingEnd = Math.min(day.rows.length, this.pageOffset + visible.length)

    const head = columns.map((col) => `<th class="num">${this.escapeHtml(col.header)}</th>`).join("")
    const body = visible.map((row) => {
      const cells = columns.map((col) => {
        const value = row.values[col.key]
        return `<td class="num">${value == null ? "—" : this.escapeHtml(this.formatCellValue(value, col.kind))}</td>`
      }).join("")
      return `
        <tr>
          <td class="time">${this.escapeHtml(this.formatClock(row.t))}</td>
          ${cells}
          <td class="status">
            <span class="dot ${row.status === "ok" ? "ok" : "warn"}" aria-label="${row.status === "ok" ? "Complete" : "Partial"}"></span>
          </td>
        </tr>
      `
    }).join("")

    this.historyTarget.innerHTML = `
      <div class="scroll">
        <table>
          <thead>
            <tr>
              <th>${this.escapeHtml(this.timeColumnLabel())}</th>
              ${head}
              <th class="center">Status</th>
            </tr>
          </thead>
          <tbody>${body}</tbody>
        </table>
      </div>
      <div class="table-foot">
        <p>Showing ${showingEnd ? this.pageOffset + 1 : 0}–${showingEnd} of ${day.rows.length} readings</p>
        <div class="pager">
          <button type="button" class="toolbar-btn" data-action="hydrograph#loadPrevious" ${this.pageOffset === 0 ? "disabled" : ""}>Previous</button>
          <button type="button" class="toolbar-btn" data-action="hydrograph#loadMore" ${this.pageOffset + PAGE_SIZE >= day.rows.length ? "disabled" : ""}>Load more</button>
        </div>
      </div>
    `
  }

  currentDay() {
    return this.groupedDays().find((day) => day.key === this.selectedDayKey) || null
  }

  tableColumns() {
    return this.uniqueMeasurements().map((measurement) => {
      const series = this.seriesByKey[measurement.parameter_code] || this.seriesByKey[measurement.kind]
      const label = series?.label || measurement.label || measurement.kind
      const unit = this.unitLabel(series || measurement)
      return {
        key: measurement.parameter_code || measurement.kind,
        kind: measurement.kind,
        header: unit ? `${label} (${unit})` : label
      }
    })
  }

  groupedDays() {
    const columns = this.uniqueMeasurements()
    const buckets = new Map()

    columns.forEach((measurement) => {
      const key = measurement.parameter_code || measurement.kind
      const series = this.seriesByKey[key]
      ;(series?.points || []).forEach((point) => {
        const date = new Date(point.t)
        if (Number.isNaN(date.getTime())) return
        const dayKey = this.dayKeyFromDate(date)
        if (!buckets.has(dayKey)) {
          buckets.set(dayKey, {
            key: dayKey,
            sort: Date.parse(`${dayKey}T00:00:00Z`),
            shortLabel: date.toLocaleDateString("en-US", this.localeOptions({
              month: "short",
              day: "numeric",
              year: "numeric"
            })),
            rowsByMinute: new Map()
          })
        }
        const day = buckets.get(dayKey)
        const minuteKey = date.toISOString().slice(0, 16)
        if (!day.rowsByMinute.has(minuteKey)) {
          day.rowsByMinute.set(minuteKey, { t: point.t, values: {}, sort: date.getTime() })
        }
        day.rowsByMinute.get(minuteKey).values[key] = point.v
      })
    })

    return Array.from(buckets.values())
      .sort((a, b) => b.sort - a.sort)
      .map((day) => {
        const rows = Array.from(day.rowsByMinute.values())
          .sort((a, b) => b.sort - a.sort)
          .map((row) => {
            const present = columns.filter((col) => row.values[col.parameter_code || col.kind] != null).length
            return {
              ...row,
              status: present === columns.length ? "ok" : "warn"
            }
          })
        return { key: day.key, shortLabel: day.shortLabel, rows }
      })
  }

  renderChart() {
    if (!this.hasCanvasTarget) return

    this.destroyChart()

    const primary = this.primarySeries()
    const companion = this.companionSeries(primary)
    if (!primary) return

    const primaryPoints = primary.points || []
    const labels = primaryPoints.map((point) => this.formatAxisLabel(point.t))
    const dayKeys = this.range === "24h"
      ? primaryPoints.map((point) => {
          const date = new Date(point.t)
          return Number.isNaN(date.getTime()) ? null : this.dayKeyFromDate(date)
        })
      : null
    const dayLabels = this.range === "24h"
      ? primaryPoints.map((point) => {
          const date = new Date(point.t)
          if (Number.isNaN(date.getTime())) return null
          return date.toLocaleDateString("en-US", this.localeOptions({
            month: "short",
            day: "numeric"
          }))
        })
      : null
    const colors = SERIES_COLORS[primary.kind] || SERIES_COLORS.discharge
    const grid = "rgba(255,255,255,0.08)"
    const tick = "#a1a1aa"
    const narrow = typeof window !== "undefined" && window.matchMedia("(max-width: 640px)").matches
    const maxTicksLimit = this.range === "24h" ? (narrow ? 4 : 6) : (narrow ? 4 : 5)

    const datasets = [{
      label: primary.label || primary.kind,
      data: primaryPoints.map((point) => point.v),
      borderColor: colors.border,
      backgroundColor: colors.fill,
      fill: true,
      tension: 0.25,
      pointRadius: 0,
      borderWidth: 2,
      yAxisID: "y",
      seriesKind: primary.kind
    }]

    if (companion && (companion.points || []).length) {
      const companionColors = SERIES_COLORS[companion.kind] || SERIES_COLORS.water_level
      const companionByMinute = new Map(
        (companion.points || []).map((point) => [String(point.t).slice(0, 16), point.v])
      )
      datasets.push({
        label: companion.label || companion.kind,
        data: primaryPoints.map((point) => companionByMinute.get(String(point.t).slice(0, 16)) ?? null),
        borderColor: companionColors.border,
        backgroundColor: "transparent",
        borderDash: [4, 4],
        fill: false,
        tension: 0.25,
        pointRadius: 0,
        borderWidth: 2,
        yAxisID: "y1",
        spanGaps: true,
        seriesKind: companion.kind
      })
    }

    const pointValues = primaryPoints.map((point) => point.v)
    const floodStages = primary.kind === "water_level"
      ? this.visibleFloodStages(pointValues, this.floodStageEntries())
      : []
    floodStages.forEach(({ key, value }) => {
      const stageColors = FLOOD_STAGE_COLORS[key]
      datasets.push({
        label: FLOOD_STAGE_LABELS[key] || key,
        data: primaryPoints.length ? primaryPoints.map(() => value) : [value],
        borderColor: stageColors.border,
        backgroundColor: "transparent",
        borderDash: [6, 4],
        fill: false,
        tension: 0,
        pointRadius: 0,
        borderWidth: 1.5,
        yAxisID: "y",
        seriesKind: "water_level",
        isFloodStage: true
      })
    })

    if (!labels.length && floodStages.length) labels.push("")

    // Only nudge the axis when visible flood stages are present. Without
    // thresholds, leave scaling to Chart.js so the series fills the plot.
    const ySuggestedMax = floodStages.length
      ? this.suggestedMaxForAxis(pointValues, floodStages.map((stage) => stage.value))
      : undefined

    try {
      this.chart = new Chart(this.canvasTarget.getContext("2d"), {
        type: "line",
        data: { labels, datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: "index", intersect: false },
          plugins: {
            legend: { display: false },
            tooltip: {
              backgroundColor: "#18181b",
              titleColor: "#fafafa",
              bodyColor: "#d4d4d8",
              borderColor: "rgba(255,255,255,0.12)",
              borderWidth: 1,
              filter: (context) => !context.dataset.isFloodStage || context.dataIndex === 0,
              callbacks: {
                label: (context) => {
                  const raw = context.parsed.y
                  if (raw == null) return `${context.dataset.label}: —`
                  if (context.dataset.isFloodStage) {
                    return `${context.dataset.label}: ${this.displayValue(raw, "water_level")} ft`
                  }
                  const series = context.dataset.seriesKind === companion?.kind ? companion : primary
                  return `${context.dataset.label}: ${this.displayValue(raw, series.kind)} ${this.unitLabel(series) || ""}`.trim()
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
                maxTicksLimit,
                maxRotation: 0,
                minRotation: 0,
                autoSkip: true,
                autoSkipPadding: narrow ? 12 : 8,
                callback: (value, index, ticks) => {
                  const label = labels[value] ?? labels[index]
                  if (!dayKeys) return label

                  const dayKey = dayKeys[value] ?? dayKeys[index]
                  if (!dayKey) return label

                  const firstForDay = ticks.find((candidate) => {
                    const candidateIndex = candidate.value ?? candidate
                    return dayKeys[candidateIndex] === dayKey
                  })
                  const firstIndex = firstForDay?.value ?? firstForDay
                  if (firstIndex === value || firstIndex === index) {
                    return dayLabels[value] ?? dayLabels[index] ?? label
                  }
                  return label
                }
              }
            },
            y: {
              display: true,
              border: { display: false },
              grid: { color: grid },
              suggestedMax: ySuggestedMax,
              ticks: {
                color: tick,
                callback: (value) => this.displayValue(value, primary.kind)
              }
            },
            ...(companion ? {
              y1: {
                display: true,
                position: "right",
                border: { display: false },
                grid: { drawOnChartArea: false },
                ticks: {
                  color: tick,
                  callback: (value) => this.displayValue(value, companion.kind)
                }
              }
            } : {})
          }
        }
      })
    } catch (error) {
      console.error("Hydrograph chart failed to render", error)
    }
  }

  suggestedMaxForAxis(pointValues, stageValues) {
    const values = [...pointValues, ...stageValues].filter((value) => Number.isFinite(value))
    if (!values.length) return undefined
    const max = Math.max(...values)
    return max > 0 ? max * 1.05 : undefined
  }

  destroyChart() {
    if (!this.chart) return
    this.chart.destroy()
    this.chart = null
  }

  formatTimestamp(value) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    const day = date.toLocaleDateString("en-US", this.localeOptions({ month: "short", day: "numeric" }))
    return `${day} at ${this.formatClock(value)}`
  }

  formatAxisLabel(value) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    if (this.range === "24h") {
      return date.toLocaleTimeString("en-US", this.localeOptions({
        hour: "2-digit",
        minute: "2-digit",
        hour12: false
      }))
    }
    if (this.range === "1y") {
      return date.toLocaleDateString("en-US", this.localeOptions({ month: "short", day: "numeric" }))
    }
    const narrow = typeof window !== "undefined" && window.matchMedia("(max-width: 640px)").matches
    if (narrow) {
      return date.toLocaleDateString("en-US", this.localeOptions({
        month: "short",
        day: "numeric"
      }))
    }
    return date.toLocaleDateString("en-US", this.localeOptions({
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit"
    }))
  }

  formatClock(value) {
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value || "—"
    return date.toLocaleTimeString("en-US", this.localeOptions({
      hour: "2-digit",
      minute: "2-digit",
      hour12: false
    }))
  }

  formatCellValue(value, kind) {
    return this.displayValue(value, kind)
  }

  displayValue(value, kind = this.series?.kind) {
    if (value == null || Number.isNaN(value)) return "—"
    if (kind === "temperature") {
      const unit = this.tempUnit()
      const converted = unit === "c" ? value : (value * 9) / 5 + 32
      return converted.toLocaleString("en-US", {
        minimumFractionDigits: 1,
        maximumFractionDigits: 1
      })
    }
    if (kind === "discharge") {
      return Math.round(value).toLocaleString("en-US")
    }
    return Number(value).toLocaleString("en-US", {
      minimumFractionDigits: 0,
      maximumFractionDigits: 2
    })
  }

  unitLabel(series) {
    if (!series) return ""
    if (series.kind === "temperature") return `°${this.tempUnit().toUpperCase()}`
    return this.formatUnit(series.unit)
  }

  formatUnit(unit) {
    if (!unit) return ""
    return String(unit).replace(/ft\^?3/gi, "ft³")
  }

  tempUnit() {
    const match = document.cookie.match(/(?:^|; )temperature_unit=([^;]*)/)
    return match && match[1] === "c" ? "c" : "f"
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
