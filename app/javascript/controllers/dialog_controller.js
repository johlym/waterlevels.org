import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["title", "body", "closeButton"]

  connect() {
    this.onCancel = this.onCancel.bind(this)
    this.onClick = this.onClick.bind(this)
    this.previouslyFocused = null
    this.element.addEventListener("cancel", this.onCancel)
    this.element.addEventListener("click", this.onClick)
  }

  disconnect() {
    this.element.removeEventListener("cancel", this.onCancel)
    this.element.removeEventListener("click", this.onClick)
    if (this.element.open) this.element.close()
  }

  show({ title, body, returnFocus } = {}) {
    if (title && this.hasTitleTarget) this.titleTarget.textContent = title
    if (body && this.hasBodyTarget) this.bodyTarget.textContent = body

    this.previouslyFocused = returnFocus || document.activeElement
    if (!this.element.open) this.element.showModal()
    document.body.classList.add("dialog-open")

    requestAnimationFrame(() => {
      if (this.hasCloseButtonTarget) this.closeButtonTarget.focus()
    })
  }

  close() {
    if (!this.element.open) return

    this.element.close()
    document.body.classList.remove("dialog-open")

    if (this.previouslyFocused?.focus) {
      this.previouslyFocused.focus()
    }
    this.previouslyFocused = null
  }

  onCancel(event) {
    event.preventDefault()
    this.close()
  }

  onClick(event) {
    if (event.target === this.element) this.close()
  }
}
