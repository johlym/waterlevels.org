module CacheableResponse
  extend ActiveSupport::Concern

  private

  # Public responses are cached at two layers with different freshness budgets:
  # - Browsers honor Cache-Control (including stale-while-revalidate). A long
  #   browser SWR makes Turbo navigations keep serving last visit's HTML until a
  #   hard reload, so browser Cache-Control stays short and has no SWR.
  # - Cloudflare honors Cloudflare-CDN-Cache-Control for edge TTL + SWR, which
  #   keeps origin load down without trapping the visitor on a stale snapshot.
  def cache_public!(max_age: 60, s_maxage: 3600, stale_while_revalidate: 86400, tags: [])
    response.set_header("Cache-Control", "public, max-age=#{max_age}, s-maxage=#{s_maxage}")
    if stale_while_revalidate.positive?
      response.set_header(
        "Cloudflare-CDN-Cache-Control",
        "max-age=#{s_maxage}, stale-while-revalidate=#{stale_while_revalidate}"
      )
    end
    response.set_header("Cache-Tag", Array(tags).join(",")) if tags.present?
  end

  def cache_static_page!
    cache_public!(max_age: 300, s_maxage: 86_400, tags: [ "static" ])
  end
end
