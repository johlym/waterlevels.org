import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["search", "type", "card", "county", "countyCount", "empty", "listings"]

  connect() {
    this.filter()
  }

  filter() {
    const query = (this.hasSearchTarget ? this.searchTarget.value : "").trim().toLowerCase()
    const activeTypes = this.typeTargets
      .filter((input) => input.checked)
      .map((input) => input.value)

    let visibleCards = 0

    this.cardTargets.forEach((card) => {
      const name = card.dataset.name || ""
      const types = (card.dataset.types || "").split(/\s+/).filter(Boolean)
      const matchesQuery = !query || name.includes(query)
      const matchesType = activeTypes.length > 0 && types.some((type) => activeTypes.includes(type))
      const visible = matchesQuery && matchesType
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
