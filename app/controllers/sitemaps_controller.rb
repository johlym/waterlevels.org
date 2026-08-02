class SitemapsController < ApplicationController
  include CacheableResponse

  def index
    cache_sitemap!(tags: [ "sitemap" ])
    render_xml Sitemap.index_xml(**sitemap_url_options)
  end

  def static
    cache_sitemap!(tags: [ "sitemap", "sitemap:static" ])
    render_xml Sitemap.static_xml(**sitemap_url_options)
  end

  def state
    code = params[:state].to_s.downcase
    raise ActiveRecord::RecordNotFound unless Usgs::StateCodes::STATES.key?(code)

    cache_sitemap!(tags: [ "sitemap", "sitemap:state:#{code}" ])
    render_xml Sitemap.state_xml(code, **sitemap_url_options)
  end

  private

  def cache_sitemap!(tags:)
    cache_public!(max_age: 3600, s_maxage: 86_400, tags: tags)
  end

  def render_xml(body)
    render body: body, content_type: "application/xml"
  end

  def sitemap_url_options
    {
      host: request.host_with_port,
      protocol: request.ssl? ? "https" : "http"
    }
  end
end
