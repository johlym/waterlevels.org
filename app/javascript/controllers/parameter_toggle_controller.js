import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab"]

  select(event) {
    const kind = event.params.kind
    const parameterCode = event.params.parameterCode
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
