import { Controller } from "@hotwired/stimulus"

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
    }
  }
}
