import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "openIcon", "closeIcon"]

  connect() {
    this.close()
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
  }

  close() {
    this.element.removeAttribute("data-open")
  }
}
