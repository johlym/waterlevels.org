import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["category", "section", "item", "trigger", "panel"]

  connect() {
    this.showCategory(this.activeCategory())
  }

  selectCategory(event) {
    const category = event.currentTarget.dataset.faqCategoryParam
    if (!category) return

    this.showCategory(category)
  }

  toggle(event) {
    const item = event.currentTarget.closest("[data-faq-target='item']")
    if (!item) return

    const opening = item.getAttribute("data-open") !== "true"
    this.closeAllItems()
    if (opening) this.openItem(item)
  }

  showCategory(category) {
    this.categoryTargets.forEach((button) => {
      const active = button.dataset.faqCategoryParam === category
      button.toggleAttribute("data-active", active)
      button.setAttribute("aria-current", active ? "true" : "false")
    })

    this.sectionTargets.forEach((section) => {
      const match = section.dataset.faqCategoryParam === category
      section.toggleAttribute("hidden", !match)
    })

    this.closeAllItems()
  }

  activeCategory() {
    const active = this.categoryTargets.find((button) => button.hasAttribute("data-active"))
    return active?.dataset.faqCategoryParam || this.categoryTargets[0]?.dataset.faqCategoryParam
  }

  closeAllItems() {
    this.itemTargets.forEach((item) => this.closeItem(item))
  }

  openItem(item) {
    item.setAttribute("data-open", "true")
    const trigger = item.querySelector("[data-faq-target='trigger']")
    const panel = item.querySelector("[data-faq-target='panel']")
    trigger?.setAttribute("aria-expanded", "true")
    panel?.removeAttribute("hidden")
  }

  closeItem(item) {
    item.removeAttribute("data-open")
    const trigger = item.querySelector("[data-faq-target='trigger']")
    const panel = item.querySelector("[data-faq-target='panel']")
    trigger?.setAttribute("aria-expanded", "false")
    panel?.setAttribute("hidden", "")
  }
}
