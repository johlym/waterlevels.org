import { Controller } from "@hotwired/stimulus"

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "textarea:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(", ")

export default class extends Controller {
  static targets = ["title", "body", "closeButton"]

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    this.previouslyFocused = null
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  show({ title, body } = {}) {
    if (title && this.hasTitleTarget) this.titleTarget.textContent = title
    if (body && this.hasBodyTarget) this.bodyTarget.textContent = body

    this.previouslyFocused = document.activeElement
    this.element.hidden = false
    document.addEventListener("keydown", this.onKeydown)
    document.body.classList.add("dialog-open")

    requestAnimationFrame(() => {
      if (this.hasCloseButtonTarget) this.closeButtonTarget.focus()
    })
  }

  close() {
    if (this.element.hidden) return

    this.element.hidden = true
    document.removeEventListener("keydown", this.onKeydown)
    document.body.classList.remove("dialog-open")

    if (this.previouslyFocused?.focus) {
      this.previouslyFocused.focus()
    }
    this.previouslyFocused = null
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }

    if (event.key !== "Tab" || this.element.hidden) return

    const focusable = this.focusableElements()
    if (!focusable.length) {
      event.preventDefault()
      return
    }

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const active = document.activeElement

    if (event.shiftKey && active === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && active === last) {
      event.preventDefault()
      first.focus()
    } else if (!this.element.contains(active)) {
      event.preventDefault()
      first.focus()
    }
  }

  focusableElements() {
    return Array.from(this.element.querySelectorAll(FOCUSABLE_SELECTOR))
      .filter((el) => !el.hasAttribute("disabled") && el.offsetParent !== null)
  }
}
