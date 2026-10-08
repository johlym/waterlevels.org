# Front of the stack so /mcp never reaches sessions, CSRF, or the gauge pipeline.
Rails.application.config.middleware.insert 0, Mcp::Gate
