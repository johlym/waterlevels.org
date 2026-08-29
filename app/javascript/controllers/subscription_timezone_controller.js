import { Controller } from "@hotwired/stimulus"

// Detects IANA time zone via Intl and syncs a hidden field + optional select.
export default class extends Controller {
  static targets = ["hidden", "label", "select", "changeButton"]

  connect() {
    this.detected = this.detectZone()
    if (this.hasHiddenTarget && !this.hiddenTarget.value) {
      this.hiddenTarget.value = this.detected
    }
    this.syncSelectFromHidden()
    this.updateLabel()
    if (this.hasSelectTarget) {
      this.selectTarget.hidden = true
    }
  }

  detectZone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || "America/New_York"
    } catch (_error) {
      return "America/New_York"
    }
  }

  updateLabel() {
    if (!this.hasLabelTarget) return
    const zone = this.hasHiddenTarget ? this.hiddenTarget.value : this.detected
    this.labelTarget.textContent = zone || "America/New_York"
  }

  syncSelectFromHidden() {
    if (!this.hasSelectTarget || !this.hasHiddenTarget) return
    const current = this.hiddenTarget.value
    if (!current) return

    const match = [...this.selectTarget.options].find((opt) => opt.value === current)
    if (match) {
      this.selectTarget.value = current
    }
  }

  showSelect(event) {
    event?.preventDefault()
    if (!this.hasSelectTarget) return
    // Keep the saved/detected zone — do not copy the select's default (often Eastern) onto the hidden field.
    this.syncSelectFromHidden()
    this.selectTarget.hidden = false
    if (this.hasChangeButtonTarget) {
      this.changeButtonTarget.hidden = true
    }
    this.updateLabel()
  }

  selectChanged() {
    if (!this.hasSelectTarget || !this.hasHiddenTarget) return
    this.hiddenTarget.value = this.selectTarget.value
    this.updateLabel()
  }
}
