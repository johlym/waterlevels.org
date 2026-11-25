// Shell entry. map.js and hydrograph.js are separate bundles so pages that
// do not draw a map or chart skip Leaflet, MapLibre, and Chart.js.
import "@hotwired/turbo-rails"
import "./controllers"

// Turbo drops a temporary tabindex after moving focus to #main, so the landmark
// keeps tabindex="-1" in the templates. On a visit that did not already focus a
// hash target, move focus to main so the next Tab enters the page content.
document.addEventListener("turbo:load", () => {
  const hash = window.location.hash
  if (hash.length > 1) {
    const target = document.getElementById(decodeURIComponent(hash.slice(1)))
    if (target && document.activeElement === target) return
  }

  const active = document.activeElement
  if (active && active !== document.body && active !== document.documentElement) return

  const main = document.getElementById("main")
  if (!main) return
  main.focus({ preventScroll: true })
})
