import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "../..")

function source(path) {
  return readFileSync(join(root, path), "utf8")
}

test("shell controller index does not import map or chart controllers", () => {
  const index = source("app/javascript/controllers/index.js")

  assert.equal(index.includes("map_controller"), false)
  assert.equal(index.includes("related_map_controller"), false)
  assert.equal(index.includes("hydrograph_controller"), false)
  assert.equal(index.includes("mobile_nav_controller"), true)
})

test("map and chart packs register on the shared Stimulus application", () => {
  const map = source("app/javascript/map.js")
  const hydrograph = source("app/javascript/hydrograph.js")

  assert.match(map, /window\.Stimulus\.register\("map"/)
  assert.match(map, /window\.Stimulus\.register\("related-map"/)
  assert.match(hydrograph, /window\.Stimulus\.register\("hydrograph"/)
})

test("hydrograph imports the line chart pieces instead of chart.js/auto", () => {
  const controller = source("app/javascript/controllers/hydrograph_controller.js")

  assert.equal(controller.includes("chart.js/auto"), false)
  for (const name of [
    "LineController",
    "LineElement",
    "PointElement",
    "CategoryScale",
    "LinearScale",
    "Filler",
    "Legend",
    "Tooltip"
  ]) {
    assert.equal(controller.includes(name), true, name)
  }
})
