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
    const prev = Date.parse(points[i - 1].t)
    const next = Date.parse(points[i].t)
    if (!Number.isFinite(prev) || !Number.isFinite(next)) continue
    if (next - prev > maxGapMs) {
      gaps.push({ start: prev, end: next })
    }
  }

  maybePushTrailingGap(gaps, points, options, maxGapMs)
  return gaps
}

function maybePushTrailingGap(gaps, points, options, maxGapMs) {
  if (!options.throughMs || !points?.length) return
  const last = Date.parse(points[points.length - 1].t)
  if (!Number.isFinite(last)) return
  if (options.throughMs - last > maxGapMs) {
    gaps.push({ start: last, end: options.throughMs })
  }
}

// Build Chart.js linear-time points, inserting a null midpoint so the stroke
// and fill break across each gap instead of bridging the hole.
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
// leaves empty gutters on both ends. Extend max only when a trailing stale-tip
// gap needs room for the hatch band.
export function continuousXScaleBounds(chartPoints, gaps = []) {
  const xs = (chartPoints || []).map((point) => point?.x).filter((x) => Number.isFinite(x))
  if (!xs.length) return {}

  let min = xs[0]
  let max = xs[0]
  for (let i = 1; i < xs.length; i += 1) {
    const x = xs[i]
    if (x < min) min = x
    if (x > max) max = x
  }

  for (const gap of gaps || []) {
    if (Number.isFinite(gap?.end) && gap.end > max) max = gap.end
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

// Draws diagonal hatch bands in gap intervals (linear x scale, ms timestamps).
export const gapHatchPlugin = {
  id: "gapHatch",
  beforeDatasetsDraw(chart, _args, pluginOptions) {
    const gaps = pluginOptions?.gaps
    if (!gaps?.length) return

    const { ctx, chartArea, scales } = chart
    const x = scales.x
    const y = scales.y
    if (!ctx || !chartArea || !x || !y) return

    const fill = pluginOptions.fillColor || "rgba(161, 161, 170, 0.35)"
    const pattern = hatchPattern(ctx, fill)

    ctx.save()
    ctx.beginPath()
    ctx.rect(chartArea.left, chartArea.top, chartArea.right - chartArea.left, chartArea.bottom - chartArea.top)
    ctx.clip()

    gaps.forEach((gap) => {
      const left = x.getPixelForValue(gap.start)
      const right = x.getPixelForValue(gap.end)
      if (!Number.isFinite(left) || !Number.isFinite(right)) return
      const width = Math.max(right - left, 1)
      ctx.fillStyle = pattern || fill
      ctx.globalAlpha = 0.55
      ctx.fillRect(left, chartArea.top, width, chartArea.bottom - chartArea.top)
    })

    ctx.restore()
  }
}
