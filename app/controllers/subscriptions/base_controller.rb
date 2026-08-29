# frozen_string_literal: true

module Subscriptions
  class BaseController < ApplicationController
    include AlertsFeatureGate

    before_action :set_no_store_headers

    private

    def enable_session?
      true
    end

    def set_no_store_headers
      response.set_header("Cache-Control", "private, no-store")
    end
  end
end
