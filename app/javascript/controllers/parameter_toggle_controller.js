import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  select(event) {
    const kind = event.params.kind
    this.element.dispatchEvent(new CustomEvent("parameter-toggle:changed", {
      bubbles: true,
      detail: { kind }
    }))
  }
}
