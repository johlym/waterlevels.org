// Match HistoryIngestion::CONTINUOUS_GAP_THRESHOLD — tip sync is ~hourly, so
// keep this above 1h. Used for chart breaks + hatch bands on continuous ranges.
export const CONTINUOUS_GAP_MS = 2 * 60 * 60 * 1000

export function isContinuousChartRange(range) {
  return range === "24h" || range === "7d" || range === "30d"
}

export function findGaps(points, maxGapMs = CONTINUOUS_GAP_MS, options = {}) {
  const gaps = []
  if (!Array.isArray(points) || points.length < 2) {
    maybePushTrailingGap(gaps, points, options, maxGapMs)
    return gaps
  }

  for (let i = 1; i < points.length; i += 1) {
    const prevPoint = points[i - 1]
    const nextPoint = points[i]
    const prev = Date.parse(prevPoint.t)
    const next = Date.parse(nextPoint.t)
    if (!Number.isFinite(prev) || !Number.isFinite(next)) continue
    if (next - prev > maxGapMs) {
      gaps.push({
        start: prev,
        end: next,
        startValue: prevPoint.v,
        endValue: nextPoint.v
      })
    }
  }

  maybePushTrailingGap(gaps, points, options, maxGapMs)
  return gaps
}

function maybePushTrailingGap(gaps, points, options, maxGapMs) {
  if (!options.throughMs || !points?.length) return
  const lastPoint = points[points.length - 1]
  const last = Date.parse(lastPoint.t)
  if (!Number.isFinite(last)) return
  if (options.throughMs - last > maxGapMs) {
    gaps.push({
      start: last,
      end: options.throughMs,
      startValue: lastPoint.v,
      endValue: null
    })
  }
}

// Build Chart.js linear-time points, inserting a null midpoint so Chart.js
// does not bezier-curve across the hole. gapHatchPlugin redraws a straight
// bridge (stroke + hashed fill) between the flanking points.
export function chartPointsWithBreaks(points, maxGapMs = CONTINUOUS_GAP_MS) {
  const out = []
  if (!Array.isArray(points)) return out

  for (let i = 0; i < points.length; i += 1) {
    const point = points[i]
    const x = Date.parse(point.t)
    if (!Number.isFinite(x)) continue

    if (i > 0) {
      const prevX = Date.parse(points[i - 1].t)
      if (Number.isFinite(prevX) && x - prevX > maxGapMs) {
        out.push({ x: (prevX + x) / 2, y: null, gap: true })
      }
    }

    out.push({
      x,
      y: point.v,
      t: point.t,
      s: point.s,
      estimated: point.s === "derived"
    })
  }

  return out
}

// Fit the linear X scale to the plotted series. Chart.js defaults to
// bounds: "ticks", which pads "nice" time past the first/last points and
// leaves empty gutters on both ends of the data.
export function continuousXScaleBounds(chartPoints) {
  const xs = (chartPoints || []).map((point) => point?.x).filter((x) => Number.isFinite(x))
  if (!xs.length) return {}

  let min = xs[0]
  let max = xs[0]
  for (let i = 1; i < xs.length; i += 1) {
    const x = xs[i]
    if (x < min) min = x
    if (x > max) max = x
  }

  if (min === max) max = min + 1
  return { min, max }
}

function hatchPattern(ctx, color) {
  if (typeof document === "undefined") return null

  const size = 8
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size
  const patternCtx = canvas.getContext("2d")
  patternCtx.strokeStyle = color
  patternCtx.lineWidth = 1
  patternCtx.beginPath()
  patternCtx.moveTo(0, size)
  patternCtx.lineTo(size, 0)
  patternCtx.stroke()
  return ctx.createPattern(canvas, "repeat")
}

function fillBaselinePixel(yScale, chartArea) {
  const zero = yScale.getPixelForValue(0)
  if (!Number.isFinite(zero)) return chartArea.bottom
  return Math.min(chartArea.bottom, Math.max(chartArea.top, zero))
}

function gapBridgeGeometry(xScale, yScale, gap) {
  if (!Number.isFinite(gap.startValue) || !Number.isFinite(gap.endValue)) return null

  const left = xScale.getPixelForValue(gap.start)
  const right = xScale.getPixelForValue(gap.end)
  const topLeft = yScale.getPixelForValue(gap.startValue)
  const topRight = yScale.getPixelForValue(gap.endValue)
  if (![left, right, topLeft, topRight].every(Number.isFinite)) return null
  if (Math.abs(right - left) < 0.5) return null

  return { left, right, topLeft, topRight }
}

// Bridges each gap with a straight stroke between the flanking points and
// hashes only the area under that segment (the data-line fill), not the
// full plot height.
export const gapHatchPlugin = {
  id: "gapHatch",
  afterDatasetsDraw(chart, _args, pluginOptions) {
    const gaps = pluginOptions?.gaps
    if (!gaps?.length) return

    const { ctx, chartArea, scales } = chart
    const x = scales.x
    const y = scales.y
    if (!ctx || !chartArea || !x || !y) return

    const hatchColor = pluginOptions.fillColor || "rgba(161, 161, 170, 0.55)"
    const strokeColor = pluginOptions.strokeColor || hatchColor
    const fillTint = pluginOptions.fillTint || "rgba(161, 161, 170, 0.12)"
    const pattern = hatchPattern(ctx, hatchColor)
    const baseline = fillBaselinePixel(y, chartArea)
    const lineWidth = pluginOptions.lineWidth || 2

    ctx.save()
    ctx.beginPath()
    ctx.rect(chartArea.left, chartArea.top, chartArea.right - chartArea.left, chartArea.bottom - chartArea.top)
    ctx.clip()

    gaps.forEach((gap) => {
      const geometry = gapBridgeGeometry(x, y, gap)
      if (!geometry) return

      const { left, right, topLeft, topRight } = geometry

      // Soft fill tint under the bridge, then diagonal hatch — scoped to the
      // series fill region between the connecting line and the origin baseline.
      ctx.beginPath()
      ctx.moveTo(left, topLeft)
      ctx.lineTo(right, topRight)
      ctx.lineTo(right, baseline)
      ctx.lineTo(left, baseline)
      ctx.closePath()
      ctx.globalAlpha = 1
      ctx.fillStyle = fillTint
      ctx.fill()
      ctx.fillStyle = pattern || hatchColor
      ctx.globalAlpha = 0.65
      ctx.fill()

      // Straight stroke connecting the two flanking observations.
      ctx.globalAlpha = 1
      ctx.strokeStyle = strokeColor
      ctx.lineWidth = lineWidth
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(left, topLeft)
      ctx.lineTo(right, topRight)
      ctx.stroke()
    })

    ctx.restore()
  }
}
