require "test_helper"

class HoneycombPipelineBoardTest < ActiveSupport::TestCase
  FakeHttp = Struct.new(:queries, :annotations, :boards, :calls) do
    def initialize
      super({}, [], [], [])
    end

    def request(method, path, body = nil)
      calls << [ method, path, body ]
      if method == :get && path == "/1/columns/waterlevels"
        return { "columns" => [] }
      end
      if method == :post && path == "/1/columns/waterlevels"
        return { "id" => "col", "key_name" => body[:key_name], "type" => body[:type] }
      end
      if method == :get && path == "/1/boards"
        return { "boards" => boards.map { |board| { "id" => board["id"], "name" => board["name"] } } }
      end
      if method == :get && path == "/1/query_annotations/waterlevels"
        return { "query_annotations" => annotations }
      end
      if method == :post && path == "/1/queries/waterlevels"
        key = JSON.generate(body)
        existing = queries.key(key)
        return { "id" => existing } if existing

        id = "q#{queries.size + 1}"
        queries[id] = key
        return { "id" => id }
      end
      if method == :post && path == "/1/query_annotations/waterlevels"
        created = JSON.parse(JSON.generate(body)).merge("id" => "a#{annotations.size + 1}")
        annotations << created
        return created
      end
      if method == :post && path == "/1/boards"
        boards << { "id" => "board1", "name" => body[:name] }
        return { "id" => "board1", "links" => { "board_url" => "https://ui.honeycomb.io/example/board/board1" } }
      end
      if method == :put && path == "/1/boards/board1"
        return { "id" => "board1", "links" => { "board_url" => "https://ui.honeycomb.io/example/board/board1" } }
      end
      if method == :delete && path == "/1/boards/board1"
        boards.clear
        return {}
      end

      raise "unexpected #{method} #{path}"
    end
  end

  test "outline groups the four pipeline questions in order" do
    outline = Honeycomb::PipelineBoard.outline
    titles = [
      "How long work takes",
      "What is not finishing",
      "Queues and pressure",
      "Dataset completeness"
    ]
    positions = titles.map { |title| outline.index(title) }

    assert_equal positions, positions.compact
    assert_equal positions, positions.sort
    assert_includes outline, "Work duration by lane"
    assert_includes outline, "Completeness by state"
    refute_includes outline, "pipeline.state = wa"
  end

  test "queries use percentiles and max gauges, not averages" do
    queries = Honeycomb::PipelineBoard.sections.flat_map { |section| section[:queries] }
    ops = queries.flat_map { |query| query[:query][:calculations].map { |calculation| calculation[:op] } }

    assert_includes ops, "P95"
    assert_includes ops, "HEATMAP"
    assert_includes ops, "MAX"
    refute_includes ops, "AVG"

    by_state = queries.find { |query| query[:name] == "Completeness by state" }
    assert_equal [ "pipeline.state" ], by_state[:query][:breakdowns]
    assert_equal "state", by_state[:query][:filters].find { |filter| filter[:column] == "pipeline.scope" }[:value]
    refute_includes by_state[:query][:calculations].map { |calculation| calculation[:column] }, "pipeline.history_ready_ratio"

    ratio = queries.find { |query| query[:name] == "National history-ready ratio" }
    assert_nil ratio[:query][:breakdowns]
    assert_equal [ "MAX" ], ratio[:query][:calculations].map { |calculation| calculation[:op] }

    stuck = queries.find { |query| query[:name] == "Stuck queues" }
    assert stuck[:query][:filters].any? { |filter| filter[:column] == "pipeline.queue.latency_s" && filter[:op] == ">" }
    assert stuck[:query][:filters].any? { |filter| filter[:column] == "pipeline.queue.workers" && filter[:value] == 0 }

    slowest = queries.find { |query| query[:name] == "Slowest history fills" }
    assert_equal 20, slowest[:query][:limit]
    assert_equal "table", slowest[:style]
  end

  test "publish creates the board once and updates it in place" do
    http = FakeHttp.new
    first = Honeycomb::PipelineBoard.new(api_key: "config-key", dataset: "waterlevels", http: http).publish!
    second = Honeycomb::PipelineBoard.new(api_key: "config-key", dataset: "waterlevels", http: http).publish!

    assert first.created
    assert_equal "https://ui.honeycomb.io/example/board/board1", first.url
    refute second.created
    assert_equal first.url, second.url
    assert_equal 1, http.calls.count { |method, path, _body| method == :post && path == "/1/boards" }
    assert_equal 1, http.calls.count { |method, path, _body| method == :put && path == "/1/boards/board1" }

    query_count = Honeycomb::PipelineBoard.sections.sum { |section| section[:queries].size }
    assert_equal query_count, http.calls.count { |method, path, _body| method == :post && path == "/1/query_annotations/waterlevels" }

    payload = http.calls.find { |method, path, _body| method == :post && path == "/1/boards" }[2]
    headers = payload[:panels].select { |panel| panel[:type] == "text" }
    assert_equal 4, headers.size
    assert_operator headers[0][:position][:y_coordinate], :<, headers[1][:position][:y_coordinate]
    assert_operator headers[1][:position][:y_coordinate], :<, headers[2][:position][:y_coordinate]
    assert_operator headers[2][:position][:y_coordinate], :<, headers[3][:position][:y_coordinate]
    assert payload[:panels].all? { |panel| panel[:position][:width].positive? }

    graphs = payload[:panels].select { |panel| panel[:type] == "query" && panel[:query_panel][:query_style] != "table" }
    assert graphs.any?
    assert graphs.all? { |panel|
      panel[:query_panel][:visualization_settings][:charts].all? { |chart| chart[:omit_missing_values] }
    }
    duration = graphs.find { |panel| panel[:query_panel][:query_style] == "graph" }
    assert_equal [ 0, 1, 2 ], duration[:query_panel][:visualization_settings][:charts].map { |chart| chart[:chart_index] }
    assert graphs.any? { |panel| panel[:query_panel][:visualization_settings][:overlaid_charts] }

    columns = http.calls.select { |method, path, _body| method == :post && path == "/1/columns/waterlevels" }
    types = columns.to_h { |_method, _path, column| [ column[:key_name], column[:type] ] }
    assert_equal "string", types["pipeline.skip_reason"]
    assert_equal "integer", types["pipeline.phase.fetch_ms"]
    assert_equal "integer", types["pipeline.phase.scope_ms"]
    assert_equal "integer", types["pipeline.retrying"]
    first_column = http.calls.index { |method, path, _body| method == :post && path == "/1/columns/waterlevels" }
    first_query = http.calls.index { |method, path, _body| method == :post && path == "/1/queries/waterlevels" }
    assert_operator first_column, :<, first_query
  end

  test "replace deletes the existing board before creating it" do
    http = FakeHttp.new
    Honeycomb::PipelineBoard.new(api_key: "config-key", dataset: "waterlevels", http: http).publish!
    replaced = Honeycomb::PipelineBoard.new(api_key: "config-key", dataset: "waterlevels", http: http).publish!(replace: true)

    assert replaced.created
    assert_equal 1, http.calls.count { |method, path, _body| method == :delete && path == "/1/boards/board1" }
    assert_equal 2, http.calls.count { |method, path, _body| method == :post && path == "/1/boards" }
  end

  test "auth failures name the configuration token and the missing permissions" do
    message = Honeycomb::PipelineBoard::Http.explain(403, { "error" => "forbidden" })

    assert_includes message, "Configuration key Token"
    assert_includes message, "Manage Queries and Columns"
    assert_includes message, "Manage Public Boards"
    assert_includes message, "forbidden"
  end

  test "a recognized key without query permission names the two board permissions" do
    message = Honeycomb::PipelineBoard::Http.explain(
      401,
      { "error" => "this API key isn't allowed to modify columns or create queries" }
    )

    assert_includes message, "cannot create queries"
    assert_includes message, "Manage Queries and Columns"
    assert_includes message, "Manage Public Boards"
    assert_includes message, "Token"
  end

  test "the default dataset is waterlevels-org and a 404 names the slug that was requested" do
    assert_equal "waterlevels-org", Honeycomb::PipelineBoard::DEFAULT_DATASET

    message = Honeycomb::PipelineBoard::Http.explain(
      404,
      { "error" => "Dataset not found" },
      path: "/1/queries/waterlevels"
    )

    assert_includes message, "waterlevels"
    assert_includes message, "HONEYCOMB_DATASET"
  end

  test "validation errors include the rejected field" do
    message = Honeycomb::PipelineBoard::Http.explain(
      422,
      {
        "error" => "The provided input is invalid.",
        "type_detail" => [ { "code" => "missing", "description" => "unknown column or derived column \"pipeline.skip_reason\"" } ]
      }
    )

    assert_includes message, "pipeline.skip_reason"
  end

  test "a key id is rejected before any request" do
    management = assert_raises(Honeycomb::PipelineBoard::Error) do
      Honeycomb::PipelineBoard::Http.new(api_key: "hcamk_example", api_base: "https://api.honeycomb.io")
    end
    configuration = assert_raises(Honeycomb::PipelineBoard::Error) do
      Honeycomb::PipelineBoard::Http.new(api_key: "hcalk_example", api_base: "https://api.honeycomb.io")
    end

    assert_includes management.message, "Management key ID"
    assert_includes configuration.message, "Configuration key ID, not its Token"
  end
end
