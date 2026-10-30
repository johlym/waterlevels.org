# Finds N+1 queries in development and in tests.
# https://github.com/charkost/prosopite
if Rails.env.development?
  # Tests scan each example instead, which already covers the requests it makes.
  require "prosopite/middleware/rack"
  Rails.configuration.middleware.use(Prosopite::Middleware::Rack)
end

Rails.application.config.after_initialize do
  if Rails.env.development?
    Prosopite.add_footer = true
    Prosopite.browser_console = true
  elsif Rails.env.test?
    Prosopite.raise = true
    Prosopite.github_annotations = ENV["GITHUB_ACTIONS"].present?
    # Factory inserts repeat by design and only set the test up.
    Prosopite.pause_during("factory_bot.run_factory")
    # Optional allowlist. Missing or empty means every repeated query fails.
    # Rebuild with PROSOPITE_RECORD_TODO=1 bin/rails test
    Prosopite.todo_file = Rails.root.join(".prosopite_todo.yml")
    Prosopite.record_todo = ENV["PROSOPITE_RECORD_TODO"].present?
  end
end
