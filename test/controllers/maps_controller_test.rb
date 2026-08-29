require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  test "exposes the CARTO basemap key to the map controller" do
    previous = ENV["CARTO_API_KEY"]
    ENV["CARTO_API_KEY"] = "test-carto-key"

    get map_path

    assert_response :success
    assert_includes response.body, 'data-map-carto-api-key-value="test-carto-key"'
  ensure
    previous.nil? ? ENV.delete("CARTO_API_KEY") : ENV["CARTO_API_KEY"] = previous
  end

  test "renders an empty carto key value when unset" do
    previous = ENV["CARTO_API_KEY"]
    ENV.delete("CARTO_API_KEY")

    get map_path

    assert_response :success
    assert_includes response.body, 'data-map-carto-api-key-value=""'
  ensure
    previous.nil? ? ENV.delete("CARTO_API_KEY") : ENV["CARTO_API_KEY"] = previous
  end
end
