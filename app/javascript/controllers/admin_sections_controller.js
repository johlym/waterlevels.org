import { Controller } from "@hotwired/stimulus"

// Load /admin Turbo Frame sections one at a time so a small Puma thread pool
// is not stampeded by six cold aggregate requests (Heroku H12 risk).
export default class extends Controller {
  static targets = ["frame"]
  static values = {
    order: { type: Array, default: ["jobs", "health", "core", "pipeline", "growth", "states"] }
  }

  connect() {
    this.pending = this.orderedFrames()
    this.boundOnFrameLoad = this.onFrameLoad.bind(this)
    this.element.addEventListener("turbo:frame-load", this.boundOnFrameLoad)
    this.element.addEventListener("turbo:frame-missing", this.boundOnFrameLoad)
    this.loadNext()
  }

  disconnect() {
    this.element.removeEventListener("turbo:frame-load", this.boundOnFrameLoad)
    this.element.removeEventListener("turbo:frame-missing", this.boundOnFrameLoad)
  }

  orderedFrames() {
    const rank = new Map(this.orderValue.map((name, index) => [name, index]))
    return this.frameTargets
      .slice()
      .sort((a, b) => {
        const aRank = rank.has(a.dataset.adminSection) ? rank.get(a.dataset.adminSection) : 99
        const bRank = rank.has(b.dataset.adminSection) ? rank.get(b.dataset.adminSection) : 99
        return aRank - bRank
      })
  }

  onFrameLoad(event) {
    if (!this.frameTargets.includes(event.target)) return
    this.loadNext()
  }

  loadNext() {
    const frame = this.pending.shift()
    if (!frame) return

    const src = frame.dataset.adminSectionsSrc
    if (!src) {
      this.loadNext()
      return
    }

    // Assigning src triggers Turbo Frame fetch.
    frame.src = src
  }
}
