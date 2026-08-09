import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { coalesceHourlyReadings } from "../../app/javascript/lib/coalesce_hourly_readings.js"

const COLUMNS = ["00065", "00060", "00010"]

function hourKey(timestamp) {
  // UTC hour buckets for deterministic tests
  return new Date(timestamp).toISOString().slice(0, 13)
}

function row(t, values) {
  return { t, sort: Date.parse(t), values }
}

describe("coalesceHourlyReadings", () => {
  it("merges staggered parameters within the same hour into one complete row", () => {
    const rows = [
      row("2026-08-07T12:00:00.000Z", { "00010": 14.2 }),
      row("2026-08-07T12:15:00.000Z", { "00065": 5.1, "00060": 1200 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 1)
    assert.equal(result[0].t, "2026-08-07T12:15:00.000Z")
    assert.deepEqual(result[0].values, {
      "00010": 14.2,
      "00065": 5.1,
      "00060": 1200
    })
    assert.equal(result[0].status, "ok")
  })

  it("keeps distinct full samples at :00 and :30 in the same hour", () => {
    const rows = [
      row("2026-08-07T12:00:00.000Z", { "00065": 5.0, "00060": 1100, "00010": 14.0 }),
      row("2026-08-07T12:30:00.000Z", { "00065": 5.2, "00060": 1250, "00010": 14.1 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 2)
    assert.equal(result[0].t, "2026-08-07T12:30:00.000Z")
    assert.equal(result[1].t, "2026-08-07T12:00:00.000Z")
    assert.equal(result[0].status, "ok")
    assert.equal(result[1].status, "ok")
    assert.equal(result[0].values["00065"], 5.2)
    assert.equal(result[1].values["00065"], 5.0)
  })

  it("does not merge when only some parameters repeat in the hour", () => {
    const rows = [
      row("2026-08-07T12:00:00.000Z", { "00065": 5.0, "00060": 1100 }),
      row("2026-08-07T12:15:00.000Z", { "00010": 14.2 }),
      row("2026-08-07T12:30:00.000Z", { "00065": 5.2, "00060": 1250 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 3)
    assert.deepEqual(result.map((r) => r.t), [
      "2026-08-07T12:30:00.000Z",
      "2026-08-07T12:15:00.000Z",
      "2026-08-07T12:00:00.000Z"
    ])
    assert.equal(result[1].status, "warn")
  })

  it("coalesces each hour independently", () => {
    const rows = [
      row("2026-08-07T12:00:00.000Z", { "00010": 14.0 }),
      row("2026-08-07T12:15:00.000Z", { "00065": 5.0, "00060": 1000 }),
      row("2026-08-07T13:00:00.000Z", { "00010": 14.5 }),
      row("2026-08-07T13:15:00.000Z", { "00065": 5.3, "00060": 1050 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 2)
    assert.equal(result[0].t, "2026-08-07T13:15:00.000Z")
    assert.equal(result[1].t, "2026-08-07T12:15:00.000Z")
    assert.equal(result[0].status, "ok")
    assert.equal(result[1].status, "ok")
  })

  it("marks coalesced rows partial when a column is still missing", () => {
    const rows = [
      row("2026-08-07T12:00:00.000Z", { "00010": 14.2 }),
      row("2026-08-07T12:15:00.000Z", { "00065": 5.1 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 1)
    assert.equal(result[0].status, "warn")
    assert.equal(result[0].values["00060"], undefined)
  })

  it("leaves a single minute row unchanged", () => {
    const rows = [
      row("2026-08-07T12:15:00.000Z", { "00065": 5.1, "00060": 1200, "00010": 14.2 })
    ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 1)
    assert.equal(result[0].status, "ok")
    assert.equal(result[0].t, "2026-08-07T12:15:00.000Z")
  })

  it("marks rows estimated when a source is estimated", () => {
    const rows = [ {
      t: "2026-07-01T00:00:00.000Z",
      sort: Date.parse("2026-07-01T00:00:00.000Z"),
      values: { "00065": 5.1, "00060": 1200, "00010": 14.2 },
      sources: { "00065": "estimated", "00060": "ok", "00010": "ok" }
    } ]

    const result = coalesceHourlyReadings(rows, COLUMNS, hourKey)

    assert.equal(result.length, 1)
    assert.equal(result[0].status, "estimated")
  })
})
