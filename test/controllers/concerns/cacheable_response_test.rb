require "test_helper"

class CacheableResponseTest < ActionDispatch::IntegrationTest
  test "public HTML keeps short browser freshness without stale-while-revalidate" do
    get root_path
    assert_response :success

    cache_control = response.headers["Cache-Control"]
    assert_includes cache_control, "public"
    assert_includes cache_control, "max-age=60"
    assert_includes cache_control, "s-maxage=3600"
    assert_not_includes cache_control, "stale-while-revalidate"

    cdn_cache = response.headers["Cloudflare-CDN-Cache-Control"]
    assert_includes cdn_cache, "max-age=3600"
    assert_includes cdn_cache, "stale-while-revalidate=86400"
  end

  test "public HTML skips the Rails session cookie so Cloudflare can cache it" do
    with_forgery_protection do
      get root_path
      assert_response :success
      assert_nil response.headers["Set-Cookie"]
      assert_not_includes response.body, 'name="csrf-token"'
    end
  end

  test "gauge pages emit specific and aggregate Cache-Tags" do
    location = create(:monitoring_location)
    with_forgery_protection do
      get "/gauges/#{location.state_code}/#{location.to_param}"
      assert_response :success
      assert_includes response.headers["Cache-Tag"], "gauge:#{location.site_number}"
      assert_includes response.headers["Cache-Tag"], "gauges"
      assert_nil response.headers["Set-Cookie"]
    end
  end

  test "static pages keep longer browser max-age without browser SWR" do
    get about_path
    assert_response :success

    cache_control = response.headers["Cache-Control"]
    assert_includes cache_control, "max-age=300"
    assert_includes cache_control, "s-maxage=86400"
    assert_not_includes cache_control, "stale-while-revalidate"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "stale-while-revalidate=86400"
  end

  test "contact remains private no-store with a session for CSRF" do
    with_forgery_protection do
      get contact_path
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_nil response.headers["Cloudflare-CDN-Cache-Control"]
      assert_includes response.headers["Set-Cookie"].to_s, "_waterlevels_session"
      assert_includes response.body, 'name="csrf-token"'
    end
  end

  private

  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
