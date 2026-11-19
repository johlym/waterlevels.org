require "test_helper"

class PageScriptsTest < ActionDispatch::IntegrationTest
  test "shell pages load the shared bundle only" do
    [ root_path, about_path, faq_path, alerts_path ].each do |path|
      get path

      assert_response :success, path
      assert_shell_script
      refute_pack_script "map"
      refute_pack_script "hydrograph"
    end
  end

  test "the map page loads the map pack and leaves it untracked" do
    get map_path

    assert_response :success
    assert_shell_script
    assert_pack_script "map"
    refute_pack_script "hydrograph"
    assert_operator response.body.index(shell_src), :<, response.body.index(pack_src("map"))
  end

  test "a gauge without a related map loads the chart pack only" do
    location = create(:monitoring_location)

    get gauge_page(location)

    assert_response :success
    assert_shell_script
    assert_pack_script "hydrograph"
    refute_pack_script "map"
    assert_select "[data-controller='related-map']", count: 0
  end

  test "a gauge with a related map loads the chart and map packs" do
    location = create(:monitoring_location, latitude: 47.5, longitude: -121.8)
    neighbor = create(
      :monitoring_location,
      name: "Nearby Creek near Town",
      slug: "nearby-creek-near-town",
      latitude: 47.55,
      longitude: -121.8,
      latest_observed_at: 20.minutes.ago
    )
    location.update!(nearby_station_ids: [ neighbor.id ])

    get gauge_page(location)

    assert_response :success
    assert_select "[data-controller='related-map']"
    assert_shell_script
    assert_pack_script "hydrograph"
    assert_pack_script "map"
    assert_operator response.body.index(shell_src), :<, response.body.index(pack_src("map"))
    assert_operator response.body.index(shell_src), :<, response.body.index(pack_src("hydrograph"))
  end

  private

  def gauge_page(location)
    "/gauges/#{location.state_code}/#{location.to_param}"
  end

  def shell_src
    %r{src="/assets/application-[^"]+\.js"}
  end

  def pack_src(name)
    %r{src="/assets/#{name}-[^"]+\.js"}
  end

  def assert_shell_script
    assert_match shell_src, response.body
    assert_match(/src="\/assets\/application-[^"]+\.js"[^>]*data-turbo-track="reload"/, response.body)
  end

  def assert_pack_script(name)
    assert_match pack_src(name), response.body
    script = css_select("script[src]").find { |node| node["src"].match?(%r{/assets/#{name}-[^/]+\.js\z}) }
    assert script, "missing #{name} script"
    assert_nil script["data-turbo-track"]
  end

  def refute_pack_script(name)
    assert_no_match pack_src(name), response.body
  end
end
