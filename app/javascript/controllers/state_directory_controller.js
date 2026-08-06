import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["search", "type", "floodStage", "alertsOnly", "card", "county", "countyCount", "empty", "listings", "countyJump"]

  connect() {
    this.filter()
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this.syncCountyJump = this.syncCountyJump.bind(this)
    this.syncCountyJump()
    this.mediaQuery.addEventListener("change", this.syncCountyJump)
  }

  disconnect() {
    this.mediaQuery?.removeEventListener("change", this.syncCountyJump)
  }

  syncCountyJump() {
    if (!this.hasCountyJumpTarget) return
    this.countyJumpTarget.open = this.mediaQuery.matches
  }

  filter() {
    const query = (this.hasSearchTarget ? this.searchTarget.value : "").trim().toLowerCase()
    const activeTypes = this.typeTargets
      .filter((input) => input.checked)
      .map((input) => input.value)
    const floodStageFilters = this.floodStageTargets
    const activeFloodStages = floodStageFilters
      .filter((input) => input.checked)
      .map((input) => input.value)
    const filterByFloodStage = floodStageFilters.length > 0
    const alertsOnly = this.hasAlertsOnlyTarget && this.alertsOnlyTarget.checked

    let visibleCards = 0

    this.cardTargets.forEach((card) => {
      const name = card.dataset.name || ""
      const types = (card.dataset.types || "").split(/\s+/).filter(Boolean)
      const floodStage = card.dataset.floodStage || ""
      const hasAlert = card.dataset.alert === "true"
      const matchesQuery = !query || name.includes(query)
      const matchesType = activeTypes.length > 0 && types.some((type) => activeTypes.includes(type))
      const matchesFloodStage = !filterByFloodStage || (activeFloodStages.length > 0 && activeFloodStages.includes(floodStage))
      const matchesAlert = !alertsOnly || hasAlert
      const visible = matchesQuery && matchesType && matchesFloodStage && matchesAlert
      card.hidden = !visible
      if (visible) visibleCards += 1
    })

    this.countyTargets.forEach((county) => {
      const cards = Array.from(county.querySelectorAll("[data-state-directory-target='card']"))
      const count = cards.filter((card) => !card.hidden).length
      county.hidden = count === 0
      const countEl = county.querySelector("[data-state-directory-target='countyCount']")
      if (countEl) {
        countEl.textContent = `${count} ${count === 1 ? "station" : "stations"}`
      }
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = visibleCards > 0
    }
  }
}
