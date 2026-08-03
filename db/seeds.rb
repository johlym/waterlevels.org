# frozen_string_literal: true

# Load demo catalog data for local development.
# One state (Washington), 100 stations, 30 days of USGS-shaped measurements.
#
#   bin/rails db:seed
#
load Rails.root.join("db/seeds/demo_state.rb")
