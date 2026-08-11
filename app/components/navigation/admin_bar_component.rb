module Navigation
  class AdminBarComponent < ViewComponent::Base
    SIDEKIQ_PATH = "/admin/sidekiq"

    def initialize(signed_in: false)
      @signed_in = signed_in
    end

    def signed_in?
      @signed_in
    end

    def nav_items
      [
        { label: "Dashboard", path: helpers.admin_path },
        { label: "Inspect", path: helpers.admin_stations_path },
        { label: "Sidekiq", path: SIDEKIQ_PATH }
      ]
    end

    def nav_link_attrs(path)
      current_admin_nav?(path) ? { "aria-current": "page" } : {}
    end

    def current_admin_nav?(path)
      return current_page?(path) if path == SIDEKIQ_PATH
      return true if path == helpers.admin_path && current_page?(helpers.admin_path)
      return true if path == helpers.admin_stations_path && request.path.start_with?("/admin/stations")

      current_page?(path)
    end
  end
end
