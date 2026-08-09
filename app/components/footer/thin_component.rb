module Footer
  class ThinComponent < ViewComponent::Base
    def initialize(year: Time.current.year)
      @year = year
    end

    def footer_link_attrs(path)
      current_page?(path) ? { "aria-current": "page" } : {}
    end
  end
end

