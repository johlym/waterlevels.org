import { describe, it } from "node:test"
import assert from "node:assert/strict"
import {
  convertTemperatureC,
  convertTemperatureDeltaC,
  formatTemperature,
  preferredTemperatureUnit,
  temperatureUnitLabel
} from "../../app/javascript/lib/temperature_unit.js"

describe("preferredTemperatureUnit", () => {
  it("defaults to fahrenheit", () => {
    assert.equal(preferredTemperatureUnit(""), "f")
    assert.equal(preferredTemperatureUnit("session=abc"), "f")
    assert.equal(preferredTemperatureUnit("temperature_unit=x"), "f")
  })

  it("reads c from the cookie", () => {
    assert.equal(preferredTemperatureUnit("temperature_unit=c"), "c")
    assert.equal(preferredTemperatureUnit("foo=1; temperature_unit=c; bar=2"), "c")
  })
})

describe("convertTemperatureC", () => {
  it("keeps celsius and converts absolutes to fahrenheit", () => {
    assert.equal(convertTemperatureC(12, "c"), 12)
    assert.equal(convertTemperatureC(12, "f"), 53.6)
    assert.equal(convertTemperatureC(0, "f"), 32)
  })

  it("returns null for non-numeric input", () => {
    assert.equal(convertTemperatureC("x", "f"), null)
  })
})

describe("convertTemperatureDeltaC", () => {
  it("scales deltas without adding 32", () => {
    assert.equal(convertTemperatureDeltaC(1, "c"), 1)
    assert.equal(convertTemperatureDeltaC(1, "f"), 1.8)
    assert.equal(convertTemperatureDeltaC(-2.5, "f"), -4.5)
  })
})

describe("formatTemperature", () => {
  it("formats to one decimal and optionally signs positives", () => {
    assert.equal(formatTemperature(53.6), "53.6")
    assert.equal(formatTemperature(1.8, { signed: true }), "+1.8")
    assert.equal(formatTemperature(-1.8, { signed: true }), "-1.8")
    assert.equal(formatTemperature(0, { signed: true }), "0.0")
  })
})

describe("temperatureUnitLabel", () => {
  it("returns degree labels", () => {
    assert.equal(temperatureUnitLabel("f"), "°F")
    assert.equal(temperatureUnitLabel("c"), "°C")
  })
})
