require "test_helper"

class ZipCodeLookupTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "extract_zip accepts five-digit and ZIP+4 forms" do
    assert_equal "98101", ZipCodeLookup.extract_zip("98101")
    assert_equal "98101", ZipCodeLookup.extract_zip("98101-1234")
    assert_equal "98101", ZipCodeLookup.extract_zip("981011234")
    assert_nil ZipCodeLookup.extract_zip("9810")
    assert_nil ZipCodeLookup.extract_zip("Seattle")
    assert_nil ZipCodeLookup.extract_zip("12101000")
  end

  test "lookup returns a map-ready centroid for a known ZIP" do
    stub_request(:get, "https://api.zippopotam.us/us/98101")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "post code" => "98101",
          "places" => [
            {
              "place name" => "Seattle",
              "longitude" => "-122.3305",
              "latitude" => "47.6114",
              "state" => "Washington",
              "state abbreviation" => "WA"
            }
          ]
        }.to_json
      )

    result = ZipCodeLookup.lookup("98101")

    assert_equal "98101", result.zip
    assert_in_delta 47.6114, result.latitude, 0.0001
    assert_in_delta(-122.3305, result.longitude, 0.0001)
    assert_equal "Seattle", result.place_name
    assert_equal "WA", result.state_code
    assert_equal "98101 — Seattle, WA", result.display_name
    assert_equal "/map?lat=47.6114&lon=-122.3305&zoom=12", result.map_path
  end

  test "lookup strips ZIP+4 before requesting" do
    stub_request(:get, "https://api.zippopotam.us/us/90210")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "post code" => "90210",
          "places" => [
            {
              "place name" => "Beverly Hills",
              "longitude" => "-118.4065",
              "latitude" => "34.0901",
              "state" => "California",
              "state abbreviation" => "CA"
            }
          ]
        }.to_json
      )

    result = ZipCodeLookup.lookup("90210-0804")
    assert_equal "90210", result.zip
    assert_requested :get, "https://api.zippopotam.us/us/90210"
  end

  test "lookup returns nil for unknown ZIP codes" do
    stub_request(:get, "https://api.zippopotam.us/us/00000")
      .to_return(status: 404, body: "{}")

    assert_nil ZipCodeLookup.lookup("00000")
  end

  test "lookup returns nil and does not raise when the provider errors" do
    stub_request(:get, "https://api.zippopotam.us/us/98101")
      .to_return(status: 503, body: "unavailable")

    assert_nil ZipCodeLookup.lookup("98101")
  end

  test "lookup caches successful responses" do
    stub_request(:get, "https://api.zippopotam.us/us/98101")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "post code" => "98101",
          "places" => [
            {
              "place name" => "Seattle",
              "longitude" => "-122.3305",
              "latitude" => "47.6114",
              "state" => "Washington",
              "state abbreviation" => "WA"
            }
          ]
        }.to_json
      )

    first = ZipCodeLookup.lookup("98101")
    second = ZipCodeLookup.lookup("98101")

    assert_equal first, second
    assert_requested :get, "https://api.zippopotam.us/us/98101", times: 1
  end
end
