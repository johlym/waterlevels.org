# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Builds the WaterLevels pipeline board: duration, unfinished work, queues,
# and dataset completeness. Publishing needs a Honeycomb configuration key
# (HONEYCOMB_CONFIG_KEY). The ingest key in OTEL_EXPORTER_OTLP_HEADERS cannot
# create boards.
module Honeycomb
  class PipelineBoard
    BOARD_NAME = "WaterLevels pipeline"
    DEFAULT_DATASET = "waterlevels"
    DEFAULT_API_BASE = "https://api.honeycomb.io"
    DAY = 86_400
    WEEK = 604_800

    Result = Struct.new(:id, :url, :created, keyword_init: true)

    class Error < StandardError; end

    class << self
      def dataset
        value = ENV["HONEYCOMB_DATASET"].to_s.strip
        value.empty? ? DEFAULT_DATASET : value
      end

      def api_base
        value = ENV["HONEYCOMB_API_ENDPOINT"].to_s.strip
        value.empty? ? DEFAULT_API_BASE : value
      end

      def outline(dataset: self.dataset)
        lines = [ BOARD_NAME, "Dataset: #{dataset}", "" ]
        sections.each do |section|
          lines << section[:title]
          section[:queries].each { |query| lines << "- #{query[:name]}" }
          lines << ""
        end
        lines.join("\n")
      end

      def sections
        @sections ||= [
          duration_section,
          unfinished_section,
          queue_section,
          completeness_section
        ]
      end

      private

      def duration_section
        section(
          "How long work takes",
          <<~MARKDOWN.strip,
            ## How long work takes
            One `pipeline.work` span per run. Read **P95(`duration_ms`)**, not the average.
            Phase time and upstream HTTP time are attributes on that span.
          MARKDOWN
          [
            graph(
              "Work duration by lane",
              "P95 and heatmap of every pipeline run, split by lane.",
              wide: true,
              calculations: [ pct("duration_ms"), heat("duration_ms"), count ],
              filters: [ eq("name", "pipeline.work") ],
              breakdowns: [ "pipeline.lane" ]
            ),
            graph(
              "History fill duration by range",
              "Station backfill only. Cold 1y fills and 3y fills are different populations.",
              calculations: [ pct("duration_ms"), heat("duration_ms"), count ],
              filters: work_lane("history_backfill"),
              breakdowns: [ "pipeline.range" ]
            ),
            graph(
              "History fill phase time",
              "Where a station fill spends time: continuous, daily, or peaks.",
              overlaid: true,
              calculations: [
                pct("pipeline.phase.continuous_ms"),
                pct("pipeline.phase.daily_ms"),
                pct("pipeline.phase.peaks_ms")
              ],
              filters: work_lane("history_backfill")
            ),
            graph(
              "Tip sync fetch vs write",
              "Latest-observation sync. Fetch is upstream time. Upsert is local writes.",
              overlaid: true,
              calculations: [
                pct("pipeline.phase.fetch_ms"),
                pct("pipeline.phase.upsert_ms"),
                pct("pipeline.http_ms")
              ],
              filters: work_lane("latest_sync")
            ),
            graph(
              "Slowest history fills",
              "The 20 slowest station backfills in the window.",
              style: "table",
              time_range: DAY,
              calculations: [ max("duration_ms") ],
              filters: work_lane("history_backfill"),
              breakdowns: [ "pipeline.site_number" ],
              orders: [ { column: "duration_ms", op: "MAX", order: "descending" } ],
              limit: 20
            ),
            graph(
              "Backfill planner scope time",
              "Candidate scan and enqueue for the history batch, not the station fill itself.",
              overlaid: true,
              time_range: WEEK,
              calculations: [
                pct("duration_ms"),
                pct("pipeline.phase.phase1_scope_ms"),
                pct("pipeline.phase.deep_scope_ms")
              ],
              filters: work_lane("history_backfill_batch")
            ),
            graph(
              "IV repair planner scope time",
              "Candidate scan time for tip repair and interior scar repair.",
              overlaid: true,
              time_range: WEEK,
              calculations: [ pct("duration_ms"), pct("pipeline.phase.scope_ms") ],
              filters: [
                eq("name", "pipeline.work"),
                { column: "pipeline.lane", op: "in", value: [ "iv_repair_batch", "iv_repair_scar_batch" ] }
              ],
              breakdowns: [ "pipeline.lane" ]
            )
          ]
        )
      end

      def unfinished_section
        section(
          "What is not finishing",
          <<~MARKDOWN.strip,
            ## What is not finishing
            `pipeline.outcome` is `ok`, `skipped`, or `error`.
            `pipeline.incomplete` means the run returned and the station was still short.
          MARKDOWN
          [
            graph(
              "Skips and errors",
              "Runs that did not finish ok, by lane and skip reason.",
              style: "combo",
              calculations: [ count ],
              filters: [ eq("name", "pipeline.work"), ne("pipeline.outcome", "ok") ],
              breakdowns: [ "pipeline.lane", "pipeline.skip_reason" ]
            ),
            graph(
              "Incomplete runs",
              "Finished calls that left the station short, and how long those calls took.",
              calculations: [ count, pct("duration_ms") ],
              filters: [ eq("name", "pipeline.work"), eq("pipeline.incomplete", true) ],
              breakdowns: [ "pipeline.lane" ]
            )
          ]
        )
      end

      def queue_section
        section(
          "Queues and pressure",
          <<~MARKDOWN.strip,
            ## Queues and pressure
            Read **MAX** of these gauges, not COUNT of events.
            `pipeline.queue.latency_s` is the age of the oldest job.
            The `default` queue also carries mail and edge-cache purge.
            A high needing-deep count with an empty queue and an open circuit means the scheduler is budget-blocked, not that workers are slow.
          MARKDOWN
          [
            graph(
              "Queue depth",
              "Jobs waiting, by data queue.",
              time_range: WEEK,
              calculations: [ max("pipeline.queue.depth") ],
              filters: [ eq("name", "pipeline.queue") ],
              breakdowns: [ "pipeline.queue" ]
            ),
            graph(
              "Oldest job age",
              "Seconds the oldest job has been waiting. Depth alone hides a stuck worker.",
              time_range: WEEK,
              calculations: [ max("pipeline.queue.latency_s") ],
              filters: [ eq("name", "pipeline.queue") ],
              breakdowns: [ "pipeline.queue" ]
            ),
            graph(
              "Stuck queues",
              "Latency above zero while no process is listening. Empty when every queue has a worker.",
              style: "table",
              time_range: WEEK,
              calculations: [
                max("pipeline.queue.depth"),
                max("pipeline.queue.latency_s"),
                max("pipeline.queue.workers")
              ],
              filters: [
                eq("name", "pipeline.queue"),
                gt("pipeline.queue.latency_s", 0),
                eq("pipeline.queue.workers", 0)
              ],
              breakdowns: [ "pipeline.queue" ]
            ),
            graph(
              "Retries, dead set, and cooldowns",
              "Work that is not on the runnable queue: Sidekiq retry and dead sets, plus backfill and IV-repair cooldowns.",
              time_range: WEEK,
              calculations: [
                max("pipeline.retry_size"),
                max("pipeline.dead_size"),
                max("pipeline.history_backfill_cooldowns"),
                max("pipeline.iv_repair_cooldowns")
              ],
              filters: [ eq("name", "pipeline.pressure") ]
            ),
            graph(
              "USGS circuits",
              "1 means that circuit is open. A missing line means the gauge has not reported it.",
              wide: true,
              overlaid: true,
              time_range: WEEK,
              calculations: [
                max("pipeline.circuit.tip"),
                max("pipeline.circuit.continuous"),
                max("pipeline.circuit.daily"),
                max("pipeline.circuit.peaks"),
                max("pipeline.circuit.iv_repair"),
                max("pipeline.circuit.iv_repair2")
              ],
              filters: [ eq("name", "pipeline.pressure") ]
            )
          ]
        )
      end

      def completeness_section
        section(
          "Dataset completeness",
          <<~MARKDOWN.strip,
            ## Dataset completeness
            Counts use the same definitions as `/admin`. Read **MAX**, not COUNT, and do not average `pipeline.history_ready_ratio` across states.
            That ratio is only on the national event.
            IV repair and scar candidate counts are omitted until a sweeper has scanned. Missing is not zero.
          MARKDOWN
          [
            graph(
              "National backlog",
              "Stations still needing a year, needing 3y, or a daily tip refresh, beside stations that are history-ready.",
              wide: true,
              overlaid: true,
              time_range: WEEK,
              calculations: [
                max("pipeline.stations_needing_history"),
                max("pipeline.stations_needing_deep"),
                max("pipeline.stations_daily_tip_refresh"),
                max("pipeline.history_ready")
              ],
              filters: [ eq("name", "pipeline.coverage"), eq("pipeline.scope", "national") ]
            ),
            graph(
              "National history-ready ratio",
              "Ready stations divided by active stations. MAX of the national event only.",
              time_range: WEEK,
              calculations: [ max("pipeline.history_ready_ratio") ],
              filters: [ eq("name", "pipeline.coverage"), eq("pipeline.scope", "national") ]
            ),
            graph(
              "History stations enqueued",
              "Stations the history batch placed on the queue. Compare with completed fills.",
              calculations: [ sum("pipeline.items") ],
              filters: work_lane("history_backfill_batch")
            ),
            graph(
              "History fills completed",
              "Station backfill runs that finished ok.",
              calculations: [ count ],
              filters: work_lane("history_backfill") + [ eq("pipeline.outcome", "ok") ]
            ),
            graph(
              "Completeness by state",
              "One row per state. These counts overlap; do not add them into a single completeness percentage.",
              wide: true,
              style: "table",
              time_range: WEEK,
              calculations: [
                max("pipeline.stations"),
                max("pipeline.history_ready"),
                max("pipeline.stations_needing_history"),
                max("pipeline.stations_needing_deep"),
                max("pipeline.stations_missing_year"),
                max("pipeline.stations_missing_continuous_anchor"),
                max("pipeline.stations_missing_continuous_tip"),
                max("pipeline.stations_missing_daily_tip"),
                max("pipeline.stations_daily_tip_refresh")
              ],
              filters: [ eq("name", "pipeline.coverage"), eq("pipeline.scope", "state") ],
              breakdowns: [ "pipeline.state" ]
            ),
            graph(
              "National tip age",
              "Active stations by age of the latest observation. Stale is missing or older than 7 days.",
              wide: true,
              overlaid: true,
              time_range: WEEK,
              calculations: [
                max("pipeline.tip_current"),
                max("pipeline.tip_h1_plus"),
                max("pipeline.tip_h6_plus"),
                max("pipeline.tip_h24_plus"),
                max("pipeline.tip_h72_plus"),
                max("pipeline.tip_stale")
              ],
              filters: [ eq("name", "pipeline.coverage"), eq("pipeline.scope", "national") ]
            ),
            graph(
              "IV repair and scar backlog",
              "Candidates from the last sweeper scan. If a series is missing, that sweeper has not recorded a scan.",
              time_range: WEEK,
              calculations: [
                max("pipeline.stations_needing_iv_repair"),
                max("pipeline.stations_needing_iv_scar")
              ],
              filters: [ eq("name", "pipeline.coverage"), eq("pipeline.scope", "national") ]
            ),
            graph(
              "Archive gaps",
              "Days pruned without R2 coverage, rows blocked from prune, and days still retrying. Summed per prune run.",
              time_range: WEEK,
              calculations: [
                sum("pipeline.gaps_alerted"),
                sum("pipeline.iv_prune_blocked"),
                sum("pipeline.retrying")
              ],
              filters: work_lane("continuous_prune")
            )
          ]
        )
      end

      def section(title, intro, queries)
        { title: title, intro: intro, queries: queries }
      end

      def graph(name, description, calculations:, filters:, breakdowns: [], time_range: DAY, **options)
        spec = {
          calculations: calculations,
          filters: filters,
          time_range: time_range
        }
        spec[:breakdowns] = breakdowns if breakdowns.any?
        spec[:orders] = options[:orders] if options[:orders]
        spec[:limit] = options[:limit] if options[:limit]
        {
          name: name,
          description: description,
          query: spec,
          wide: options[:wide] || false,
          style: options[:style] || "graph",
          overlaid: options[:overlaid] || false
        }
      end

      def work_lane(lane)
        [ eq("name", "pipeline.work"), eq("pipeline.lane", lane) ]
      end

      def eq(column, value)
        { column: column, op: "=", value: value }
      end

      def ne(column, value)
        { column: column, op: "!=", value: value }
      end

      def gt(column, value)
        { column: column, op: ">", value: value }
      end

      def count
        { op: "COUNT" }
      end

      def pct(column)
        { op: "P95", column: column }
      end

      def heat(column)
        { op: "HEATMAP", column: column }
      end

      def max(column)
        { op: "MAX", column: column }
      end

      def sum(column)
        { op: "SUM", column: column }
      end
    end

    def initialize(api_key:, dataset: self.class.dataset, api_base: self.class.api_base, http: nil)
      @dataset = dataset
      @http = http || Http.new(api_key: api_key, api_base: api_base)
    end

    def publish!(replace: false)
      existing = find_board
      if existing && replace
        @http.request(:delete, "/1/boards/#{existing.fetch('id')}")
        existing = nil
      end

      payload = board_payload
      if existing
        result = @http.request(:put, "/1/boards/#{existing.fetch('id')}", payload)
        created = false
      else
        result = @http.request(:post, "/1/boards", payload)
        created = true
      end

      Result.new(
        id: result["id"] || existing&.fetch("id"),
        url: result.dig("links", "board_url"),
        created: created
      )
    end

    def board_payload
      {
        name: BOARD_NAME,
        description: self.class::DESCRIPTION,
        type: "flexible",
        layout_generation: "manual",
        panels: layout.map { |panel| api_panel(panel) }
      }
    end

    DESCRIPTION = "Duration, queue pressure, and dataset completeness for the WaterLevels pipeline. " \
      "Gauges are pipeline.queue, pipeline.pressure, and pipeline.coverage: read MAX of the value, not COUNT of events. " \
      "Work duration is duration_ms on pipeline.work."

    private

    def layout
      y = 0
      panels = []
      self.class.sections.each do |section|
        panels << { kind: :text, content: section[:intro], x: 0, y: y, w: 12, h: 3 }
        y += 3
        row_x = 0
        row_height = 0
        section[:queries].each do |query|
          width = query[:wide] ? 12 : 6
          height = query[:wide] ? 8 : 6
          if row_x + width > 12
            y += row_height
            row_x = 0
            row_height = 0
          end
          panels << query.merge(kind: :query, x: row_x, y: y, w: width, h: height)
          row_x += width
          row_height = [ row_height, height ].max
          next unless row_x >= 12

          y += row_height
          row_x = 0
          row_height = 0
        end
        y += row_height if row_x.positive?
      end
      panels
    end

    def api_panel(panel)
      position = {
        x_coordinate: panel[:x],
        y_coordinate: panel[:y],
        width: panel[:w],
        height: panel[:h]
      }
      if panel[:kind] == :text
        return { type: "text", position: position, text_panel: { content: panel[:content] } }
      end

      query_id = ensure_query(panel[:query])
      annotation_id = ensure_annotation(query_id, panel[:name], panel[:description])
      query_panel = {
        query_id: query_id,
        query_annotation_id: annotation_id,
        query_style: panel[:style]
      }
      if panel[:overlaid]
        query_panel[:visualization_settings] = { overlaid_charts: true }
      end
      { type: "query", position: position, query_panel: query_panel }
    end

    def ensure_query(spec)
      key = JSON.generate(spec)
      @query_ids ||= {}
      return @query_ids[key] if @query_ids[key]

      created = @http.request(:post, "/1/queries/#{@dataset}", spec)
      @query_ids[key] = created.fetch("id")
    end

    def ensure_annotation(query_id, name, description)
      found = annotations.find { |annotation| annotation["name"] == name && annotation["query_id"] == query_id }
      return found.fetch("id") if found

      created = @http.request(
        :post,
        "/1/query_annotations/#{@dataset}",
        { name: name, query_id: query_id, description: description }
      )
      annotations << created
      created.fetch("id")
    end

    def annotations
      @annotations ||= begin
        body = @http.request(:get, "/1/query_annotations/#{@dataset}")
        collection(body, "query_annotations")
      end
    end

    def find_board
      page = "/1/boards"
      while page
        body = @http.request(:get, page)
        found = collection(body, "boards").find { |board| board["name"] == BOARD_NAME }
        return found if found

        page = body.is_a?(Hash) ? body.dig("links", "next") : nil
      end
      nil
    end

    def collection(body, key)
      return body if body.is_a?(Array)

      Array(body[key] || body["data"])
    end

    # Configuration-key client. The key is sent only as a header.
    class Http
      def initialize(api_key:, api_base:)
        problem = self.class.credential_problem(api_key)
        raise Error, problem if problem

        @api_key = api_key.to_s.strip
        @api_base = api_base
      end

      # Configuration keys authenticate with the Token alone. The Key ID is only
      # a label: hc…ik_ ingest, hc…lk_ configuration, hc…mk_ management.
      def self.credential_problem(value)
        key = value.to_s.strip
        if key.empty?
          return "Set HONEYCOMB_CONFIG_KEY to the Configuration key Token. The Key ID is not the credential."
        end

        case key
        when /\Ahc[a-z]mk_/
          "That value is a Management key ID. It only labels the key in the UI. " \
            "A Management key cannot create boards, even joined to its secret. " \
            "Create a Configuration key in the environment, enable Manage Queries and Columns and Manage Public Boards, " \
            "and set HONEYCOMB_CONFIG_KEY to that key's Token."
        when /\Ahc[a-z]lk_/
          "That value is a Configuration key ID, not its Token. " \
            "Open the key in Honeycomb and copy the Token into HONEYCOMB_CONFIG_KEY. " \
            "The key needs Manage Queries and Columns and Manage Public Boards."
        when /\Ahc[a-z]ik_/
          "That value is an Ingest key ID. Ingest keys send telemetry and cannot create boards. " \
            "Set HONEYCOMB_CONFIG_KEY to a Configuration key Token with Manage Queries and Columns and Manage Public Boards."
        end
      end

      def request(method, path, body = nil)
        uri = path.start_with?("http") ? URI(path) : URI.join(@api_base, path)
        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
        http_request = klass.new(uri)
        http_request["X-Honeycomb-Team"] = @api_key
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body) if body

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.open_timeout = 10
          http.read_timeout = 30
          http.request(http_request)
        end
        parsed = parse_body(response.body)
        return parsed if response.is_a?(Net::HTTPSuccess)

        raise Error, self.class.explain(response.code.to_i, parsed)
      end

      def self.explain(status, body)
        detail = summarize(body)
        if detail.include?("isn't allowed to modify columns") || detail.include?("not allowed to modify columns")
          return "Honeycomb accepted this key, but it cannot create queries. " \
            "On that Configuration key, enable Manage Queries and Columns and Manage Public Boards, " \
            "then set HONEYCOMB_CONFIG_KEY to the Token rather than the Key ID. #{detail}".strip
        end
        if detail.include?("unknown API key")
          return "Honeycomb did not recognize this value (#{status}). " \
            "A Key ID starts with hc and ik, lk, or mk and is not the credential. " \
            "Configuration keys use the Token alone. If this is the Token, set HONEYCOMB_API_ENDPOINT for the region. " \
            "#{detail}".strip
        end
        if status == 401 || status == 403
          "Honeycomb refused the key (#{status}). Use a Configuration key Token with " \
            "Manage Queries and Columns and Manage Public Boards, not an ingest key. #{detail}".strip
        else
          "Honeycomb request failed (#{status}). #{detail}".strip
        end
      end

      def self.summarize(body)
        return "" if body.nil? || body == {}

        text = body["error"] || body["title"] || body["detail"]
        if (text.nil? || text.to_s.empty?) && body["errors"]
          text = Array(body["errors"]).filter_map { |error| error["detail"] || error["title"] }.join("; ")
        end
        text.to_s[0, 500]
      end

      def parse_body(raw)
        text = raw.to_s
        return {} if text.strip.empty?

        JSON.parse(text)
      rescue JSON::ParserError
        { "error" => text[0, 500] }
      end
    end
  end
end
