require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "ef" * 32
  FRONT_DOOR = "mcp-test-front-door"

  setup do
    @previous = ENV["WATERLEVELS_MCP_TOKEN"]
    @previous_front_door = ENV["WATERLEVELS_MCP_FRONT_DOOR"]
    ENV["WATERLEVELS_MCP_TOKEN"] = TOKEN
    ENV["WATERLEVELS_MCP_FRONT_DOOR"] = FRONT_DOOR
    McpController::RATE_LIMIT_STORE.clear
  end

  teardown do
    restore_env("WATERLEVELS_MCP_TOKEN", @previous)
    restore_env("WATERLEVELS_MCP_FRONT_DOOR", @previous_front_door)
    Mcp::Inflight.release
  end

  test "unset token returns 404" do
    ENV.delete("WATERLEVELS_MCP_TOKEN")
    mcp_post(rpc("ping"))

    assert_response :not_found
  end

  test "short token returns 404" do
    ENV["WATERLEVELS_MCP_TOKEN"] = "secret"
    mcp_post(rpc("ping"))

    assert_response :not_found
  end

  test "missing bearer returns 401" do
    post "/mcp", params: rpc("ping"), headers: { "X-Blue-Alpha-Spooky" => FRONT_DOOR }, as: :json

    assert_response :unauthorized
    assert_equal "Bearer", response.headers["WWW-Authenticate"]
    assert_not_includes response.body.to_s, TOKEN
  end

  test "missing or wrong front door header returns 404 even with the bearer token" do
    post "/mcp", params: rpc("ping"), headers: { "Authorization" => "Bearer #{TOKEN}" }, as: :json
    assert_response :not_found
    assert_not_includes response.body.to_s, FRONT_DOOR

    mcp_post(rpc("ping"), front_door: "wrong-front-door-value")
    assert_response :not_found
    assert_not_includes response.body.to_s, FRONT_DOOR
    assert_not_includes response.body.to_s, "wrong-front-door-value"
  end

  test "short or unset front door returns 404" do
    ENV["WATERLEVELS_MCP_FRONT_DOOR"] = "too-short"
    mcp_post(rpc("ping"))
    assert_response :not_found

    ENV.delete("WATERLEVELS_MCP_FRONT_DOOR")
    mcp_post(rpc("ping"))
    assert_response :not_found
  end

  test "oversized front door header returns 404 without hashing" do
    replace_singleton(Digest::SHA256, :hexdigest)
    mcp_post(rpc("ping"), front_door: "z" * 600)

    assert_response :not_found
  ensure
    restore_singletons
  end

  test "wrong bearer returns 401" do
    mcp_post(rpc("ping"), token: "0" * 64)

    assert_response :unauthorized
    assert_equal "Bearer", response.headers["WWW-Authenticate"]
    assert_not_includes response.body.to_s, TOKEN
  end

  test "initialize and tools/list advertise the five read-only tools" do
    mcp_post(rpc("initialize", id: 1, params: { protocolVersion: "2025-06-18", capabilities: {} }))

    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "2025-06-18", json.dig("result", "protocolVersion")
    assert_equal false, json.dig("result", "capabilities", "tools", "listChanged")
    assert_equal "waterlevels", json.dig("result", "serverInfo", "name")
    assert_equal "1.0.0", json.dig("result", "serverInfo", "version")
    assert_nil response.headers["Mcp-Session-Id"]

    mcp_post(rpc("tools/list", id: 2))
    names = json.dig("result", "tools").map { |tool| tool["name"] }
    assert_equal %w[search_stations get_station station_trend series_summary list_flooding], names
  end

  test "notifications/initialized returns 202 with an empty body" do
    mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" })

    assert_response :accepted
    assert_empty response.body
  end

  test "authenticated GET, DELETE, and HEAD are not allowed" do
    headers = { "Authorization" => "Bearer #{TOKEN}", "X-Blue-Alpha-Spooky" => FRONT_DOOR }
    get "/mcp", headers: headers
    assert_response :method_not_allowed

    delete "/mcp", headers: headers
    assert_response :method_not_allowed

    head "/mcp", headers: headers
    assert_response :method_not_allowed
  end

  test "batches and parse errors are JSON-RPC errors" do
    mcp_post_raw("[]")
    assert_response :bad_request
    assert_equal(-32_600, json.dig("error", "code"))

    mcp_post_raw("{")
    assert_response :bad_request
    assert_equal(-32_700, json.dig("error", "code"))
  end

  test "get_station returns the denormalized row" do
    location = build_station
    mcp_post(tool_call("get_station", { site_number: location.site_number }))

    assert_response :success
    body = json.dig("result", "structuredContent")
    assert_not json.dig("result", "isError")
    assert_equal location.display_name, body["name"]
    assert_equal "U.S. Geological Survey", body["agency"]
    assert_equal "/gauges/wa/#{location.to_param}", body["path"]
    assert_equal 12.5, body.dig("water_level", "value")
    assert_equal "00065", body.dig("water_level", "parameter_code")
    assert_equal 40.0, body.dig("discharge", "value")
    assert_equal 10.0, body.dig("temperature", "celsius")
    assert_equal 50.0, body.dig("temperature", "fahrenheit")
    assert_equal 9.0, body.dig("stages", "minor")
    assert_equal "water_level", body.dig("series", 0, "kind")
    text = JSON.parse(json.dig("result", "content", 0, "text"))
    assert_equal body["name"], text["name"]
  end

  test "station_trend reports a 24h delta" do
    location = build_station
    series = location.time_series.first
    observed_at = Time.zone.parse("2026-06-15 18:00:00")
    series.create_latest_observation!(
      observed_at: observed_at,
      value: 12.5,
      synced_at: Time.current,
      unit_of_measure: "ft"
    )
    ContinuousObservation.create!(
      time_series: series,
      observed_at: observed_at - 25.hours,
      value: 10.0
    )

    mcp_post(tool_call("station_trend", { site_number: location.site_number }))

    assert_response :success
    body = json.dig("result", "structuredContent")
    assert_not json.dig("result", "isError")
    assert_equal 12.5, body["value"]
    assert_equal "ft", body["unit"]
    assert_equal 2.5, body["delta_24h"]
    assert_not_nil body["percent_24h"]
    assert body.key?("delta_yoy")
  end

  test "search_stations finds a station by site number" do
    location = build_station
    mcp_post(tool_call("search_stations", { query: location.site_number }))

    assert_response :success
    hits = json.dig("result", "structuredContent", "stations")
    station = hits.find { |hit| hit["type"] == "station" && hit["id"] == location.site_number }
    assert station
    assert_equal "/gauges/wa/#{location.to_param}", station["path"]
    assert_includes station.keys, "flood_category"
    assert_includes [ true, false ], station["stale"]
  end

  test "list_flooding returns alert stations" do
    location = build_station(flood_category: "major")
    mcp_post(tool_call("list_flooding", { state: "WA", category: "major" }))

    assert_response :success
    rows = json.dig("result", "structuredContent", "stations")
    assert_equal [ location.site_number ], rows.map { |row| row["site_number"] }
    assert_equal "major", rows.first["flood_category"]
    assert_equal "Major Flooding", rows.first["flood_category_label"]
    assert_equal 12.5, rows.first.dig("water_level", "value")
  end

  test "series_summary on 24h uses continuous coverage" do
    location = build_station
    series = location.time_series.first
    seed_continuous_coverage!(series, from: 6.hours.ago, to: Time.current, step: 1.hour, value: 4.25)

    mcp_post(tool_call("series_summary", { site_number: location.site_number, range: "24h" }))

    assert_response :success
    body = json.dig("result", "structuredContent")
    assert_not json.dig("result", "isError")
    assert_operator body["count"], :>, 0
    assert_equal 4.25, body["min"]
    assert_equal 4.25, body["max"]
    assert_equal 0.0, body["delta"]
    assert body["earliest"]["t"]
    assert body["latest"]["v"]
  end

  test "rejected search query does not query" do
    replace_singleton(MonitoringLocation, :search)
    replace_singleton(MonitoringLocation, :exact_search_match)
    replace_singleton(ZipCodeLookup, :lookup)
    mcp_post(tool_call("search_stations", { query: "a" * 65 }))

    assert_response :success
    assert_equal true, json.dig("result", "isError")
  ensure
    restore_singletons
  end

  test "bad site_number does not query" do
    replace_singleton(MonitoringLocation, :find_by)
    mcp_post(tool_call("get_station", { site_number: "bad id" }))

    assert_response :success
    assert_equal true, json.dig("result", "isError")
  ensure
    restore_singletons
  end

  test "unknown flood category does not query" do
    replace_singleton(MonitoringLocation, :flood_alert)
    mcp_post(tool_call("list_flooding", { category: "severe" }))

    assert_response :success
    assert_equal true, json.dig("result", "isError")
  ensure
    restore_singletons
  end

  test "a second tools/call while inflight is held returns 429" do
    assert Mcp::Inflight.try_acquire
    replace_singleton(MonitoringLocation, :find_by)
    mcp_post(tool_call("get_station", { site_number: "12345678" }))

    assert_response :too_many_requests
    assert_equal "private, no-store", response.headers["Cache-Control"]
  ensure
    restore_singletons
  end

  private

  def rpc(method, id: 1, params: nil)
    body = { jsonrpc: "2.0", id: id, method: method }
    body[:params] = params if params
    body
  end

  def tool_call(name, arguments, id: 1)
    rpc("tools/call", id: id, params: { name: name, arguments: arguments })
  end

  def mcp_post(payload, token: TOKEN, front_door: FRONT_DOOR)
    post "/mcp",
      params: payload,
      headers: auth_headers(token:, front_door:),
      as: :json
  end

  def mcp_post_raw(body, token: TOKEN, front_door: FRONT_DOOR)
    post "/mcp",
      params: body,
      headers: auth_headers(token:, front_door:).merge("Content-Type" => "application/json")
  end

  def auth_headers(token:, front_door:)
    headers = { "Authorization" => "Bearer #{token}" }
    headers["X-Blue-Alpha-Spooky"] = front_door unless front_door.nil?
    headers
  end

  def restore_env(key, previous)
    if previous.nil?
      ENV.delete(key)
    else
      ENV[key] = previous
    end
  end

  def json
    JSON.parse(response.body)
  end

  def replace_singleton(klass, name)
    singleton = klass.singleton_class
    @replacements ||= []
    backup = :"_mcp_test_backup_#{name}_#{@replacements.length}"
    singleton.alias_method backup, name
    test_case = self
    singleton.define_method(name) { |*| test_case.flunk("called #{klass}.#{name}") }
    @replacements << [ singleton, name, backup ]
  end

  def restore_singletons
    Array(@replacements).reverse_each do |singleton, name, backup|
      singleton.alias_method name, backup
      singleton.remove_method backup
    end
    @replacements = []
  end

  def build_station(**attrs)
    location = create(:monitoring_location, {
      state_code: "wa",
      flood_category: "minor",
      flood_stage_action: 7,
      flood_stage_minor: 9,
      flood_stage_moderate: 11,
      flood_stage_major: 13,
      latest_water_level_value: 12.5,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_discharge_value: 40,
      latest_discharge_unit: "ft3/s",
      latest_temperature_c: 10,
      latest_observed_at: 1.hour.ago,
      has_water_level: true,
      has_discharge: true,
      has_temperature: true
    }.merge(attrs))
    create(:time_series, monitoring_location: location, parameter_code: "00065", measurement_kind: "water_level", unit_of_measure: "ft")
    location
  end
end
