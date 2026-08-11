module Admin
  class SettingsController < BaseController
    def show
      @groups = Admin::SettingsRegistry.groups
    end

    def update
      group_key = params[:group].to_s.to_sym
      group = Admin::SettingsRegistry.groups.find { |entry| entry.key == group_key }
      unless group
        redirect_to admin_settings_path, alert: "Unknown settings group."
        return
      end

      values = params.fetch(:settings, {}).permit!.to_h
      updated = []
      group.settings.each do |setting|
        key = setting.key.to_s
        next unless values.key?(key)

        raw = values[key]
        raw = raw.last if raw.is_a?(Array)
        AppConfig.write!(setting.key, raw)
        updated << setting.label
      end

      redirect_to admin_settings_path(anchor: group_key),
        notice: updated.empty? ? "No changes saved." : "Saved: #{updated.join(", ")}."
    rescue ArgumentError => e
      redirect_to admin_settings_path(anchor: group_key), alert: e.message
    end

    def reset
      key = params[:key].to_s.to_sym
      setting = Admin::SettingsRegistry.setting(key)
      unless setting
        redirect_to admin_settings_path, alert: "Unknown setting."
        return
      end

      AppConfig.reset!(key)
      redirect_to admin_settings_path(anchor: setting.group_key),
        notice: "Reset #{setting.label} to ENV/default."
    end
  end
end
