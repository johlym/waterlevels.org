module Admin
  # Declarative catalog of admin-tunable settings and maintenance actions.
  # Definitions live under Admin::Settings::* and are registered in to_prepare.
  class SettingsRegistry
    Setting = Data.define(
      :key,
      :type,
      :default,
      :label,
      :description,
      :env,
      :min,
      :max,
      :group_key
    ) do
      def boolean?
        type == :boolean
      end

      def integer?
        type == :integer
      end

      def env_key
        env.presence
      end
    end

    Action = Data.define(
      :key,
      :label,
      :description,
      :danger,
      :confirm,
      :group_key,
      :callable
    ) do
      def danger?
        danger
      end

      def call
        callable.call
      end
    end

    Group = Data.define(:key, :title, :description, :settings, :actions)

    class << self
      def reset!
        @groups = {}
        @group_order = []
        @settings = {}
        @actions = {}
        @current_group = nil
      end

      def group(key, title:, description:, &block)
        key = key.to_sym
        raise ArgumentError, "duplicate settings group #{key}" if @groups&.key?(key)
        raise ArgumentError, "group requires a block" unless block

        @groups ||= {}
        @group_order ||= []
        @settings ||= {}
        @actions ||= {}

        @group_order << key
        @groups[key] = { title: title, description: description, setting_keys: [], action_keys: [] }
        previous = @current_group
        @current_group = key
        instance_eval(&block)
      ensure
        @current_group = previous
      end

      def boolean(key, default:, label:, description:, env: nil)
        register_setting(key, type: :boolean, default: default, label: label, description: description, env: env)
      end

      def integer(key, default:, label:, description:, env: nil, min: nil, max: nil)
        register_setting(
          key,
          type: :integer,
          default: default,
          label: label,
          description: description,
          env: env,
          min: min,
          max: max
        )
      end

      def action(key, label:, description:, danger: false, confirm: nil, &block)
        raise ArgumentError, "actions must be declared inside a group" if @current_group.nil?
        raise ArgumentError, "action requires a block" unless block

        key = key.to_sym
        raise ArgumentError, "duplicate maintenance action #{key}" if @actions.key?(key)

        @actions[key] = Action.new(
          key: key,
          label: label,
          description: description,
          danger: danger,
          confirm: confirm.presence || (danger ? "Run #{label}? This can increase load or drop warm caches." : "Run #{label}?"),
          group_key: @current_group,
          callable: block
        )
        @groups[@current_group][:action_keys] << key
      end

      def groups
        Array(@group_order).map { |key| build_group(key) }
      end

      def setting(key)
        @settings&.[](key.to_sym)
      end

      def settings
        (@settings || {}).values
      end

      def action_for(key)
        @actions&.[](key.to_sym)
      end

      def actions
        (@actions || {}).values
      end

      def registered?
        @groups.present?
      end

      private

      def register_setting(key, type:, default:, label:, description:, env:, min: nil, max: nil)
        raise ArgumentError, "settings must be declared inside a group" if @current_group.nil?
        raise ArgumentError, "description required for #{key}" if description.blank?
        raise ArgumentError, "label required for #{key}" if label.blank?

        key = key.to_sym
        raise ArgumentError, "duplicate setting #{key}" if @settings.key?(key)

        coerced_default = coerce_default(type, default)
        @settings[key] = Setting.new(
          key: key,
          type: type,
          default: coerced_default,
          label: label,
          description: description,
          env: env&.to_s,
          min: min,
          max: max,
          group_key: @current_group
        )
        @groups[@current_group][:setting_keys] << key
      end

      def coerce_default(type, value)
        case type
        when :boolean then ActiveModel::Type::Boolean.new.cast(value)
        when :integer then Integer(value)
        else value
        end
      end

      def build_group(key)
        meta = @groups.fetch(key)
        Group.new(
          key: key,
          title: meta[:title],
          description: meta[:description],
          settings: meta[:setting_keys].map { |setting_key| @settings.fetch(setting_key) },
          actions: meta[:action_keys].map { |action_key| @actions.fetch(action_key) }
        )
      end
    end

    reset!
  end
end
