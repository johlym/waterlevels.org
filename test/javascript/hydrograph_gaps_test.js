import { describe, it } from "node:test"
import assert from "node:assert/strict"
import {
  CONTINUOUS_GAP_MS,
  chartPointsWithBreaks,
  continuousXScaleBounds,
  findGaps,
  isContinuousChartRange
} from "../../app/javascript/lib/hydrograph_gaps.js"

describe("hydrograph_gaps", () => {
  it("treats 24h/7d/30d as continuous chart ranges", () => {
    assert.equal(isContinuousChartRange("24h"), true)
    assert.equal(isContinuousChartRange("7d"), true)
    assert.equal(isContinuousChartRange("30d"), true)
    assert.equal(isContinuousChartRange("1y"), false)
  })

  it("finds interior gaps larger than the threshold", () => {
    const points = [
      { t: "2026-08-10T03:30:00.000Z", v: 1 },
      { t: "2026-08-10T13:30:00.000Z", v: 2 }
    ]
    const gaps = findGaps(points)
    assert.equal(gaps.length, 1)
    assert.equal(gaps[0].end - gaps[0].start, 10 * 60 * 60 * 1000)
  })

  it("ignores healthy tip-sync spacing under the threshold", () => {
    const points = [
      { t: "2026-08-10T12:00:00.000Z", v: 1 },
      { t: "2026-08-10T13:00:00.000Z", v: 2 }
    ]
    assert.deepEqual(findGaps(points), [])
  })

  it("adds a trailing gap through now when the tip is stale", () => {
    const points = [ { t: "2026-08-10T12:00:00.000Z", v: 1 } ]
    const throughMs = Date.parse("2026-08-10T16:00:00.000Z")
    const gaps = findGaps(points, CONTINUOUS_GAP_MS, { throughMs })
    assert.equal(gaps.length, 1)
    assert.equal(gaps[0].start, Date.parse("2026-08-10T12:00:00.000Z"))
    assert.equal(gaps[0].end, throughMs)
  })

  it("inserts null midpoints so the chart stroke breaks across gaps", () => {
    const points = [
      { t: "2026-08-10T03:30:00.000Z", v: 1 },
      { t: "2026-08-10T13:30:00.000Z", v: 2 }
    ]
    const chartPoints = chartPointsWithBreaks(points)
    assert.equal(chartPoints.length, 3)
    assert.equal(chartPoints[1].y, null)
    assert.equal(chartPoints[1].gap, true)
    assert.equal(chartPoints[0].y, 1)
    assert.equal(chartPoints[2].y, 2)
  })

  it("fits the X scale to first/last chart points", () => {
    const points = [
      { t: "2026-08-10T03:30:00.000Z", v: 1 },
      { t: "2026-08-10T13:30:00.000Z", v: 2 }
    ]
    const chartPoints = chartPointsWithBreaks(points)
    assert.deepEqual(continuousXScaleBounds(chartPoints), {
      min: Date.parse("2026-08-10T03:30:00.000Z"),
      max: Date.parse("2026-08-10T13:30:00.000Z")
    })
  })

  it("extends the X scale max for a trailing stale-tip gap hatch", () => {
    const points = [ { t: "2026-08-10T12:00:00.000Z", v: 1 } ]
    const throughMs = Date.parse("2026-08-10T16:00:00.000Z")
    const chartPoints = chartPointsWithBreaks(points)
    const gaps = findGaps(points, CONTINUOUS_GAP_MS, { throughMs })
    assert.deepEqual(continuousXScaleBounds(chartPoints, gaps), {
      min: Date.parse("2026-08-10T12:00:00.000Z"),
      max: throughMs
    })
  })
})
