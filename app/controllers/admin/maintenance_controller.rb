module Admin
  class MaintenanceController < BaseController
    def create
      key = params[:key].to_s.to_sym
      action = Admin::SettingsRegistry.action_for(key)
      unless action
        redirect_to admin_settings_path, alert: "Unknown maintenance action."
        return
      end

      if action.danger? && params[:confirm].to_s != action.key.to_s
        redirect_to admin_settings_path(anchor: action.group_key),
          alert: "Confirm #{action.label} by submitting the danger action again."
        return
      end

      result = action.call
      Rails.logger.info(
        "[admin/maintenance] action=#{key} result=#{result.inspect}"
      )

      notice = result == :enqueued ? "#{action.label} enqueued." : "#{action.label} completed."
      redirect_to admin_settings_path(anchor: action.group_key), notice: notice
    rescue StandardError => e
      Rails.logger.error("[admin/maintenance] action=#{key} error=#{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      redirect_to admin_settings_path(anchor: :maintenance),
        alert: "#{action&.label || key}: #{e.message}"
    end
  end
end
