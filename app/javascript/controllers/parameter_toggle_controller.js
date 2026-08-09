import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab"]

  connect() {
    this.element.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.onKeydown)
  }

  select(event) {
    const kind = event.params.kind
    const parameterCode = event.params.parameterCode
    this.activate(parameterCode, kind)
  }

  onKeydown = (event) => {
    if (!this.hasTabTarget) return
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return

    const tabs = this.tabTargets
    const currentIndex = tabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true")
    if (currentIndex < 0) return

    event.preventDefault()
    let nextIndex = currentIndex
    if (event.key === "ArrowRight") nextIndex = (currentIndex + 1) % tabs.length
    if (event.key === "ArrowLeft") nextIndex = (currentIndex - 1 + tabs.length) % tabs.length
    if (event.key === "Home") nextIndex = 0
    if (event.key === "End") nextIndex = tabs.length - 1

    const next = tabs[nextIndex]
    next.focus()
    this.activate(
      next.dataset.parameterToggleParameterCodeParam,
      next.dataset.parameterToggleKindParam
    )
  }

  activate(parameterCode, kind) {
    this.tabTargets.forEach((tab) => {
      const selected =
        tab.dataset.parameterToggleParameterCodeParam === String(parameterCode)
      tab.setAttribute("aria-selected", selected ? "true" : "false")
      tab.tabIndex = selected ? 0 : -1
    })
    this.element.dispatchEvent(new CustomEvent("parameter-toggle:changed", {
      bubbles: true,
      detail: { kind, parameterCode }
    }))
  }
}
