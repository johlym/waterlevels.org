import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "../..")

function readStylesheets(dir) {
  const parts = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) {
      parts.push(readStylesheets(path))
    } else if (entry.name.endsWith(".css")) {
      parts.push(readFileSync(path, "utf8"))
    }
  }
  return parts.join("\n")
}

const css = readStylesheets(join(root, "app/assets/stylesheets"))

test("readable text does not use under-contrast zinc-500", () => {
  assert.equal(css.includes("text-zinc-500"), false)
})

test("placeholders use zinc-400 or brighter", () => {
  assert.equal(css.includes("placeholder:text-zinc-600"), false)
  assert.equal(css.includes("placeholder:text-zinc-500"), false)
  assert.match(css, /placeholder:text-zinc-400/)
})

test("global focus-visible outline is defined", () => {
  assert.match(css, /:focus-visible\s*\{/)
  assert.match(css, /outline:\s*2px solid/)
})

test("skip link styles exist", () => {
  assert.match(css, /\.skip-link\s*\{/)
})

test("reduced motion preference is honored globally", () => {
  assert.match(css, /prefers-reduced-motion:\s*reduce/)
})
