import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "openIcon", "closeIcon", "toggle"]

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    this.close({ restoreFocus: false })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  toggle() {
    if (this.element.hasAttribute("data-open")) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.element.setAttribute("data-open", "true")
    this.syncToggle(true)
    document.addEventListener("keydown", this.onKeydown)

    requestAnimationFrame(() => {
      const firstLink = this.panelTarget?.querySelector("a, button")
      firstLink?.focus()
    })
  }

  close({ restoreFocus = true } = {}) {
    const wasOpen = this.element.hasAttribute("data-open")
    this.element.removeAttribute("data-open")
    this.syncToggle(false)
    document.removeEventListener("keydown", this.onKeydown)

    if (restoreFocus && wasOpen && this.hasToggleTarget) {
      this.toggleTarget.focus()
    }
  }

  syncToggle(open) {
    if (!this.hasToggleTarget) return
    this.toggleTarget.setAttribute("aria-expanded", open ? "true" : "false")
    this.toggleTarget.setAttribute("aria-label", open ? "Close main menu" : "Open main menu")
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.element.hasAttribute("data-open")) {
      event.preventDefault()
      this.close()
    }
  }
}
