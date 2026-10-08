module Mcp
  # Stateless JSON-RPC for MCP protocol 2025-06-18. No Mcp-Session-Id.
  # Batches (JSON arrays) are rejected. Tool work is delegated to Mcp::Tools.
  class Server
    PROTOCOL_VERSION = "2025-06-18"
    SERVER_NAME = "waterlevels"
    SERVER_VERSION = "1.0.0"

    Request = Data.define(:id, :method_name, :params, :notification) do
      def tool_call?
        method_name == "tools/call" && !notification
      end
    end

    Outcome = Data.define(:status, :body) do
      def empty?
        body.nil?
      end
    end

    class << self
      def parse(raw)
        begin
          data = JSON.parse(raw.to_s)
        rescue JSON::ParserError
          return error_outcome(400, nil, -32_700, "Parse error")
        end

        return error_outcome(400, nil, -32_600, "Invalid Request") unless data.is_a?(Hash)

        id = data.key?("id") ? data["id"] : nil
        notification = !data.key?("id")
        method_name = data["method"]
        unless data["jsonrpc"] == "2.0" && method_name.is_a?(String) && valid_id?(id)
          return error_outcome(400, nil, -32_600, "Invalid Request")
        end

        Request.new(id: id, method_name: method_name, params: data["params"], notification: notification)
      end

      def handle(request)
        case request.method_name
        when "initialize"
          return accepted if request.notification

          success(request.id, initialize_result)
        when "notifications/initialized"
          accepted
        when "ping"
          return accepted if request.notification

          success(request.id, {})
        when "tools/list"
          return accepted if request.notification

          success(request.id, { tools: Mcp::Tools.definitions })
        when "tools/call"
          return accepted if request.notification

          success(request.id, Mcp::Tools.call(tool_name(request), tool_arguments(request)))
        else
          return accepted if request.notification

          error_outcome(400, request.id, -32_601, "Method not found")
        end
      end

      def busy_body(id)
        {
          jsonrpc: "2.0",
          id: id,
          error: { code: -32_000, message: "Too Many Requests" }
        }
      end

      private

      def initialize_result
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
        }
      end

      def tool_name(request)
        params = request.params
        return unless params.is_a?(Hash)

        name = params["name"]
        name if name.is_a?(String)
      end

      def tool_arguments(request)
        params = request.params
        return {} unless params.is_a?(Hash)

        params.key?("arguments") ? params["arguments"] : {}
      end

      def valid_id?(id)
        id.nil? || id.is_a?(String) || id.is_a?(Numeric)
      end

      def success(id, result)
        Outcome.new(status: 200, body: { jsonrpc: "2.0", id: id, result: result })
      end

      def accepted
        Outcome.new(status: 202, body: nil)
      end

      def error_outcome(status, id, code, message)
        Outcome.new(
          status: status,
          body: { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
        )
      end
    end
  end
end
