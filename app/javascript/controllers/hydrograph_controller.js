import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"
import { firstPartyApiFetch } from "../lib/api"
import { formatGaugeValue } from "../lib/gauge_value"
import { coalesceHourlyReadings } from "../lib/coalesce_hourly_readings"
import {
  chartPointsWithBreaks,
  continuousXScaleBounds,
  findGaps,
  gapHatchPlugin,
  isContinuousChartRange
} from "../lib/hydrograph_gaps"
import {
  convertTemperatureC,
  formatTemperature,
  preferredTemperatureUnit,
  temperatureUnitLabel
} from "../lib/temperature_unit"

const SERIES_COLORS = {
  discharge: { border: "#22d3ee", fill: "rgba(34, 211, 238, 0.18)", legend: "bg-cyan" },
  water_level: { border: "#60a5fa", fill: "rgba(96, 165, 250, 0.12)", legend: "bg-blue" },
  temperature: { border: "#2dd4bf", fill: "rgba(45, 212, 191, 0.12)", legend: "bg-teal" }
}

const FLOOD_STAGE_COLORS = {
  action: { border: "#fbbf24", legend: "bg-flood-action", dash: [6, 4] },
  minor: { border: "#fb923c", legend: "bg-flood-minor", dash: [2, 2] },
  moderate: { border: "#f43f5e", legend: "bg-flood-moderate", dash: [8, 3, 2, 3] },
  major: { border: "#ef4444", legend: "bg-flood-major", dash: [12, 4] }
}

const FLOOD_STAGE_LABELS = {
  action: "Action stage",
  minor: "Minor flood",
  moderate: "Moderate flood",
  major: "Major flood"
}

const FLOOD_STAGE_ORDER = ["action", "minor", "moderate", "major"]

export default class extends Controller {
  static targets = ["canvas", "history", "rangeButton", "legend", "stats", "daySelect", "estimatedNote"]
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
    this.load()
  }

  selectDay() {
    if (!this.hasDaySelectTarget) return
    this.selectedDayKey = this.daySelectTarget.value
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
        const response = await firstPartyApiFetch(`${this.urlValue}?${params.toString()}`)
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
    this.updateCanvasLabel(primary)
    this.renderLegend()
    this.renderStats(primary.points || [])
    this.renderEstimatedNote(primary.points || [])
    this.renderChart()
    this.renderDaySelect()
    this.renderHistory()
  }

  updateCanvasLabel(series) {
    if (!this.hasCanvasTarget) return
    const label = series.label || series.kind || "Measurement"
    const unit = this.unitLabel(series)
    const rangeLabels = { "7d": "7 days", "30d": "30 days", "1y": "1 year", "3y": "3 years" }
    const range = rangeLabels[this.range] || this.range
    const unitSuffix = unit ? ` in ${unit}` : ""
    this.canvasTarget.setAttribute(
      "aria-label",
      `Trend chart for ${label}${unitSuffix} over ${range}. Use the hourly measurements table below for the same data.`
    )
  }

  hasEstimatedPoints(points = []) {
    return points.some((point) => point.s === "derived")
  }

  renderEstimatedNote(points) {
    if (!this.hasEstimatedNoteTarget) return
    const dailyRange = this.range === "1y" || this.range === "3y"
    const show = dailyRange && this.hasEstimatedPoints(points)
    this.estimatedNoteTarget.hidden = !show
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

  // Secondary overlays drawn with the primary: stage/flow companion, plus
  // temperature when present and not already selected as the primary series.
  overlaySeries(primary) {
    if (!primary) return []

    const overlays = []
    const companion = this.companionSeries(primary)
    if (companion && (companion.points || []).length) overlays.push(companion)

    const temperature = Object.values(this.seriesByKey).find((series) => series.kind === "temperature")
    if (
      temperature
      && temperature !== primary
      && temperature.kind !== primary.kind
      && (temperature.points || []).length
    ) {
      overlays.push(temperature)
    }

    return overlays
  }

  renderLegend() {
    if (!this.hasLegendTarget) return
    const primary = this.primarySeries()
    const items = [primary, ...this.overlaySeries(primary)].filter(Boolean)
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

  // Keep the Y domain anchored to the observed series. Only overlay flood
  // thresholds that already fall inside (or just above) that window so
  // distant major/moderate lines do not leave a large empty band.
  visibleFloodStages(pointValues, stageEntries) {
    if (!stageEntries.length) return []

    const points = pointValues.filter((value) => Number.isFinite(value))
    if (!points.length) return stageEntries

    const dataMax = Math.max(...points)
    const dataMin = Math.min(...points)
    const span = Math.max(dataMax - dataMin, Math.abs(dataMax) * 0.08, 0.25)
    // Allow the next stage only when it is a near-term proximity cue.
    const proximity = Math.max(span * 0.75, Math.abs(dataMax) * 0.12, 0.5)
    const ceiling = dataMax + proximity

    return stageEntries.filter((stage) => stage.value <= ceiling)
  }

  emptyRangeMessage() {
    const dailyRange = this.range === "1y" || this.range === "3y"
    if (dailyRange && this.series?.usgs_daily_absent) {
      const label = this.series.label || "this measurement"
      return `USGS does not publish daily values for ${label}. Try 30 Days or shorter for continuous readings.`
    }
    return "No observations for this range yet."
  }

  renderStats(points) {
    if (!this.hasStatsTarget) return

    if (!points.length) {
      this.statsTarget.innerHTML = `<p class="empty">${this.emptyRangeMessage()}</p>`
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
      this.historyTarget.innerHTML = `<p class="empty">${this.emptyRangeMessage()}</p>`
      return
    }

    const columns = this.tableColumns()
    const count = day.rows.length

    const head = columns.map((col) => `<th scope="col" class="num">${this.escapeHtml(col.header)}</th>`).join("")
    const body = day.rows.map((row) => {
      const cells = columns.map((col) => {
        const value = row.values[col.key]
        return `<td class="num">${value == null ? "—" : this.escapeHtml(this.formatCellValue(value, col.kind))}</td>`
      }).join("")
      const status = row.status === "estimated"
        ? { className: "warn", label: "Estimated" }
        : row.status === "ok"
          ? { className: "ok", label: "Complete" }
          : { className: "warn", label: "Partial" }
      return `
        <tr>
          <td class="time">${this.escapeHtml(this.formatClock(row.t))}</td>
          ${cells}
          <td class="status">
            <span class="status-pill ${status.className}">
              <span class="dot" aria-hidden="true"></span>
              ${status.label}
            </span>
          </td>
        </tr>
      `
    }).join("")

    const estimatedFootnote = day.rows.some((row) => row.status === "estimated")
      ? `<p class="aside">Estimated daily mean from continuous data (USGS daily unavailable).</p>`
      : ""

    this.historyTarget.innerHTML = `
      <div class="scroll">
        <table>
          <caption class="sr-only">Hourly observations for ${this.escapeHtml(day.key)}</caption>
          <thead>
            <tr>
              <th scope="col">${this.escapeHtml(this.timeColumnLabel())}</th>
              ${head}
              <th scope="col" class="center">Status</th>
            </tr>
          </thead>
          <tbody>${body}</tbody>
        </table>
      </div>
      <div class="table-foot">
        <p>${count} ${count === 1 ? "reading" : "readings"}</p>
        ${estimatedFootnote}
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
    const columnKeys = columns.map((col) => col.parameter_code || col.kind)
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
        const minuteKey = this.minuteKeyFromDate(date)
        if (!day.rowsByMinute.has(minuteKey)) {
          day.rowsByMinute.set(minuteKey, { t: point.t, values: {}, sources: {}, sort: date.getTime() })
        }
        const row = day.rowsByMinute.get(minuteKey)
        row.values[key] = point.v
        row.sources[key] = point.s === "derived" ? "estimated" : "ok"
      })
    })

    return Array.from(buckets.values())
      .sort((a, b) => b.sort - a.sort)
      .map((day) => {
        const rows = coalesceHourlyReadings(
          Array.from(day.rowsByMinute.values()),
          columnKeys,
          (timestamp) => this.hourKeyFromTimestamp(timestamp)
        )
        return { key: day.key, shortLabel: day.shortLabel, rows }
      })
  }

  minuteKeyFromDate(date) {
    const { year, month, day } = this.dayParts(date)
    const hour = this.clockPart(date, "hour")
    const minute = this.clockPart(date, "minute")
    return `${year}-${month}-${day}T${hour}:${minute}`
  }

  hourKeyFromTimestamp(timestamp) {
    const date = new Date(timestamp)
    if (Number.isNaN(date.getTime())) return ""
    const { year, month, day } = this.dayParts(date)
    const hour = this.clockPart(date, "hour")
    return `${year}-${month}-${day}T${hour}`
  }

  clockPart(date, type) {
    const parts = new Intl.DateTimeFormat("en-US", this.localeOptions({
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23"
    })).formatToParts(date)
    return parts.find((part) => part.type === type)?.value?.padStart(2, "0") || "00"
  }

  renderChart() {
    if (!this.hasCanvasTarget) return

    this.destroyChart()

    const primary = this.primarySeries()
    const overlays = this.overlaySeries(primary)
    if (!primary) return

    const primaryPoints = primary.points || []
    const continuousRange = isContinuousChartRange(this.range)
    const colors = SERIES_COLORS[primary.kind] || SERIES_COLORS.discharge
    const grid = "rgba(255,255,255,0.08)"
    const tick = "#a1a1aa"
    const narrow = typeof window !== "undefined" && window.matchMedia("(max-width: 640px)").matches
    const maxTicksLimit = this.range === "24h" ? (narrow ? 4 : 6) : (narrow ? 4 : 5)

    const chartPoints = continuousRange
      ? chartPointsWithBreaks(primaryPoints)
      : primaryPoints.map((point) => point.v)
    const labels = continuousRange ? undefined : primaryPoints.map((point) => this.formatAxisLabel(point.t))
    const estimatedFlags = continuousRange
      ? chartPoints.map((point) => Boolean(point?.estimated))
      : primaryPoints.map((point) => point.s === "derived")
    // Interior gaps only — do not stretch the X scale out to "now" for a
    // trailing stale tip; that reintroduces empty time after the last point.
    // gapHatchPlugin bridges each hole with a straight stroke and hashes only
    // the fill under that bridge (not the full plot height). Overlay series
    // (flow / temperature) get stroke-only bridges at 50% opacity.
    const gaps = continuousRange ? findGaps(primaryPoints) : []
    const bridgeSeries = continuousRange
      ? [{
          gaps,
          yAxisID: "y",
          strokeColor: colors.border,
          fillColor: colors.border,
          fillTint: colors.fill,
          lineWidth: 2,
          opacity: 1,
          hatch: true
        }]
      : []

    const datasets = [{
      label: primary.label || primary.kind,
      data: chartPoints,
      borderColor: colors.border,
      backgroundColor: colors.fill,
      fill: true,
      tension: 0.25,
      spanGaps: false,
      pointRadius: estimatedFlags.map((estimated) => estimated ? 3 : 0),
      pointHoverRadius: estimatedFlags.map((estimated) => estimated ? 4 : 3),
      pointBackgroundColor: estimatedFlags.map((estimated) => estimated ? colors.border : "transparent"),
      pointBorderColor: estimatedFlags.map((estimated) => estimated ? "#09090b" : "transparent"),
      pointBorderWidth: 1,
      borderWidth: 2,
      yAxisID: "y",
      seriesKind: primary.kind,
      estimatedFlags,
      parsing: continuousRange ? false : undefined
    }]

    const overlayAxes = {}
    overlays.forEach((overlay, index) => {
      const overlayColors = SERIES_COLORS[overlay.kind] || SERIES_COLORS.discharge
      // Flow / temperature overlays stay at half opacity so the primary fill
      // series remains the visual focus; gap bridges match that weight.
      const overlayBorder = this.colorWithAlpha(overlayColors.border, 0.5)
      const yAxisID = `y${index + 1}`
      const overlayPoints = overlay.points || []
      let overlayData
      if (continuousRange) {
        // Own timeline + breaks so primary gap midpoints do not carve holes in
        // overlays that still have readings; plugin bridges overlay gaps at 50%.
        overlayData = chartPointsWithBreaks(overlayPoints)
        const overlayGaps = findGaps(overlayPoints)
        if (overlayGaps.length) {
          bridgeSeries.push({
            gaps: overlayGaps,
            yAxisID,
            strokeColor: overlayBorder,
            lineWidth: 2,
            opacity: 1,
            hatch: false,
            borderDash: [4, 4]
          })
        }
      } else {
        const overlayByMinute = new Map(
          overlayPoints.map((point) => [String(point.t).slice(0, 16), point.v])
        )
        overlayData = primaryPoints.map((point) => overlayByMinute.get(String(point.t).slice(0, 16)) ?? null)
      }

      datasets.push({
        label: overlay.label || overlay.kind,
        data: overlayData,
        borderColor: overlayBorder,
        backgroundColor: "transparent",
        borderDash: [4, 4],
        fill: false,
        tension: 0.25,
        pointRadius: 0,
        borderWidth: 2,
        yAxisID,
        spanGaps: !continuousRange,
        seriesKind: overlay.kind,
        parsing: continuousRange ? false : undefined
      })

      overlayAxes[yAxisID] = {
        display: true,
        position: "right",
        offset: index > 0,
        border: { display: false },
        grid: { drawOnChartArea: false },
        ticks: {
          color: tick,
          callback: (value) => this.displayValue(value, overlay.kind)
        }
      }
    })

    const pointValues = primaryPoints.map((point) => point.v)
    const floodStages = primary.kind === "water_level"
      ? this.visibleFloodStages(pointValues, this.floodStageEntries())
      : []
    floodStages.forEach(({ key, value }) => {
      const stageColors = FLOOD_STAGE_COLORS[key]
      let stageData
      if (continuousRange) {
        stageData = chartPoints.length
          ? chartPoints.map((point) => ({ x: point.x, y: point?.gap ? null : value }))
          : []
      } else {
        stageData = primaryPoints.length ? primaryPoints.map(() => value) : [value]
      }
      datasets.push({
        label: FLOOD_STAGE_LABELS[key] || key,
        data: stageData,
        borderColor: stageColors.border,
        backgroundColor: "transparent",
        borderDash: stageColors.dash || [6, 4],
        fill: false,
        tension: 0,
        pointRadius: 0,
        borderWidth: 2,
        yAxisID: "y",
        seriesKind: "water_level",
        isFloodStage: true,
        parsing: continuousRange ? false : undefined
      })
    })

    if (!continuousRange && !labels.length && floodStages.length) labels.push("")

    // Only nudge the axis when visible flood stages are present. Without
    // thresholds, leave scaling to Chart.js so the series fills the plot.
    const ySuggestedMax = floodStages.length
      ? this.suggestedMaxForAxis(pointValues, floodStages.map((stage) => stage.value))
      : undefined

    const dayKeys = (!continuousRange && this.range === "24h")
      ? primaryPoints.map((point) => {
          const date = new Date(point.t)
          return Number.isNaN(date.getTime()) ? null : this.dayKeyFromDate(date)
        })
      : null
    const dayLabels = dayKeys
      ? primaryPoints.map((point) => {
          const date = new Date(point.t)
          if (Number.isNaN(date.getTime())) return null
          return date.toLocaleDateString("en-US", this.localeOptions({
            month: "short",
            day: "numeric"
          }))
        })
      : null

    const seriesByKind = {
      [primary.kind]: primary,
      ...Object.fromEntries(overlays.map((series) => [series.kind, series]))
    }

    try {
      this.chart = new Chart(this.canvasTarget.getContext("2d"), {
        type: "line",
        data: continuousRange ? { datasets } : { labels, datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: "index", intersect: false },
          plugins: {
            legend: { display: false },
            gapHatch: continuousRange && bridgeSeries.some((entry) => entry.gaps?.length)
              ? { series: bridgeSeries }
              : false,
            tooltip: {
              backgroundColor: "#18181b",
              titleColor: "#fafafa",
              bodyColor: "#d4d4d8",
              borderColor: "rgba(255,255,255,0.12)",
              borderWidth: 1,
              filter: (context) => {
                if (context.dataset.isFloodStage) return context.dataIndex === 0
                if (context.raw?.gap || context.parsed?.y == null) return false
                return true
              },
              callbacks: {
                title: (items) => {
                  const item = items?.[0]
                  if (!item) return ""
                  if (continuousRange) {
                    const ms = item.parsed?.x
                    if (!Number.isFinite(ms)) return ""
                    return this.formatTimestamp(new Date(ms).toISOString())
                  }
                  return item.label || ""
                },
                label: (context) => {
                  const raw = context.parsed.y
                  if (raw == null) return `${context.dataset.label}: —`
                  if (context.dataset.isFloodStage) {
                    return `${context.dataset.label}: ${this.displayValue(raw, "water_level")} ft`
                  }
                  const series = seriesByKind[context.dataset.seriesKind] || primary
                  const estimated = Array.isArray(context.dataset.estimatedFlags)
                    && context.dataset.estimatedFlags[context.dataIndex]
                  const suffix = estimated ? " (Estimated)" : ""
                  return `${context.dataset.label}: ${this.displayValue(raw, series.kind)} ${this.unitLabel(series) || ""}${suffix}`.trim()
                }
              }
            }
          },
          scales: {
            x: continuousRange ? {
              type: "linear",
              bounds: "data",
              ...continuousXScaleBounds(chartPoints),
              display: true,
              border: { display: false },
              grid: { color: grid },
              ticks: {
                color: tick,
                maxTicksLimit,
                maxRotation: 0,
                minRotation: 0,
                callback: (value) => this.formatAxisLabel(new Date(value).toISOString())
              }
            } : {
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
            ...overlayAxes
          }
        },
        plugins: continuousRange ? [ gapHatchPlugin ] : []
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

  colorWithAlpha(color, alpha) {
    const value = String(color || "").trim()
    const hex = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i)
    if (hex) {
      let body = hex[1]
      if (body.length === 3) {
        body = body.split("").map((ch) => `${ch}${ch}`).join("")
      }
      const r = Number.parseInt(body.slice(0, 2), 16)
      const g = Number.parseInt(body.slice(2, 4), 16)
      const b = Number.parseInt(body.slice(4, 6), 16)
      return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }

    const rgb = value.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*[\d.]+\s*)?\)$/i)
    if (rgb) {
      return `rgba(${rgb[1]}, ${rgb[2]}, ${rgb[3]}, ${alpha})`
    }

    return value
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
    if (this.range === "3y") {
      return date.toLocaleDateString("en-US", this.localeOptions({
        month: "short",
        day: "numeric",
        year: "2-digit"
      }))
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
      const converted = convertTemperatureC(value, this.tempUnit())
      return formatTemperature(converted) ?? "—"
    }
    if (kind === "discharge") {
      return formatGaugeValue(value, 0) ?? "—"
    }
    return formatGaugeValue(value, 2) ?? "—"
  }

  unitLabel(series) {
    if (!series) return ""
    if (series.kind === "temperature") return temperatureUnitLabel(this.tempUnit())
    return this.formatUnit(series.unit)
  }

  formatUnit(unit) {
    if (!unit) return ""
    return String(unit).replace(/ft\^?3/gi, "ft³")
  }

  tempUnit() {
    return preferredTemperatureUnit(document.cookie)
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
