# frozen_string_literal: true

module AlertsFeatureGate
  extend ActiveSupport::Concern

  included do
    before_action :require_alerts_enabled!
  end

  private

  def require_alerts_enabled!
    head :not_found if AlertsConfig.disabled?
  end
end
