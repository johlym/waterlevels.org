module CacheableResponse
  extend ActiveSupport::Concern

  private

  def cache_public!(max_age: 60, s_maxage: 3600, tags: [])
    response.set_header("Cache-Control", "public, max-age=#{max_age}, s-maxage=#{s_maxage}, stale-while-revalidate=86400")
    response.set_header("Cache-Tag", Array(tags).join(",")) if tags.present?
  end

  def cache_static_page!
    cache_public!(max_age: 300, s_maxage: 86_400, tags: ["static"])
  end
end
