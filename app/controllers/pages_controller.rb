class PagesController < ApplicationController
  include CacheableResponse

  PAGES = %w[about contact disclosures privacy terms].freeze

  def show
    @page = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless PAGES.include?(@page)

    if @page == "contact"
      @contact_message = ContactMessage.new
      # Form needs fresh CSRF + Turnstile; do not edge-cache.
      response.set_header("Cache-Control", "private, no-store")
    else
      cache_static_page!
    end

    render template: "pages/#{@page}"
  end
end
