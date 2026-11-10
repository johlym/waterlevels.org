# frozen_string_literal: true

namespace :honeycomb do
  desc "Create or update the WaterLevels pipeline board. Set HONEYCOMB_CONFIG_KEY. DRY_RUN=1 prints the layout. REPLACE=1 deletes the existing board first."
  task :board do
    require Rails.root.join("lib/honeycomb/pipeline_board")

    if ENV["DRY_RUN"] == "1"
      puts Honeycomb::PipelineBoard.outline
      next
    end

    result = Honeycomb::PipelineBoard.new(api_key: ENV.fetch("HONEYCOMB_CONFIG_KEY", nil)).publish!(
      replace: ENV["REPLACE"] == "1"
    )
    puts result.created ? "Created #{result.url || result.id}" : "Updated #{result.url || result.id}"
  end
end
