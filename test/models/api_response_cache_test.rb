require "test_helper"

class ApiResponseCacheTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "fetch_map_stations caches by bbox until map invalidation" do
    calls = 0
    first = ApiResponseCache.fetch_map_stations("-125,45,-120,49") do
      calls += 1
      { stations: [ { id: "1" } ] }
    end
    second = ApiResponseCache.fetch_map_stations("-125,45,-120,49") do
      calls += 1
      { stations: [ { id: "2" } ] }
    end

    assert_equal 1, calls
    assert_equal first, second

    ApiResponseCache.invalidate_map!

    third = ApiResponseCache.fetch_map_stations("-125,45,-120,49") do
      calls += 1
      { stations: [ { id: "3" } ] }
    end

    assert_equal 2, calls
    assert_equal [ { id: "3" } ], third[:stations]
  end

  test "observation cache invalidates per site without clearing other sites" do
    calls = { "a" => 0, "b" => 0 }

    ApiResponseCache.fetch_observations(site_number: "a", parameter_code: "00065", kind: "water_level", range: "7d") do
      calls["a"] += 1
      { points: [ 1 ] }
    end
    ApiResponseCache.fetch_observations(site_number: "b", parameter_code: "00065", kind: "water_level", range: "7d") do
      calls["b"] += 1
      { points: [ 2 ] }
    end

    ApiResponseCache.invalidate_observations!("a")

    ApiResponseCache.fetch_observations(site_number: "a", parameter_code: "00065", kind: "water_level", range: "7d") do
      calls["a"] += 1
      { points: [ 11 ] }
    end
    ApiResponseCache.fetch_observations(site_number: "b", parameter_code: "00065", kind: "water_level", range: "7d") do
      calls["b"] += 1
      { points: [ 22 ] }
    end

    assert_equal 2, calls["a"]
    assert_equal 1, calls["b"]
  end

  test "invalidate_after_sync bumps map and all observations" do
    map_calls = 0
    obs_calls = 0

    ApiResponseCache.fetch_map_search("texas") do
      map_calls += 1
      { stations: [] }
    end
    ApiResponseCache.fetch_observations(site_number: "1", parameter_code: "00060", kind: "discharge", range: "24h") do
      obs_calls += 1
      { points: [] }
    end

    ApiResponseCache.invalidate_after_sync!

    ApiResponseCache.fetch_map_search("texas") do
      map_calls += 1
      { stations: [ { id: "x" } ] }
    end
    ApiResponseCache.fetch_observations(site_number: "1", parameter_code: "00060", kind: "discharge", range: "24h") do
      obs_calls += 1
      { points: [ 1 ] }
    end

    assert_equal 2, map_calls
    assert_equal 2, obs_calls
  end
end
