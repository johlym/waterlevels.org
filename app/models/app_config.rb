# Runtime reader for admin-tunable settings.
# Resolution: DB override → ENV (when the setting declares env:) → code default.
class AppConfig
  CACHE_PREFIX = "app_config/v1".freeze
  CACHE_TTL = 30.seconds

  class UnknownKeyError < KeyError; end

  class << self
    def get(key)
      definition = definition!(key)
      cached(definition.key) { resolve(definition) }
    end

    def boolean?(key)
      ActiveModel::Type::Boolean.new.cast(get(key))
    end

    def integer(key)
      Integer(get(key))
    end

    def source(key)
      definition = definition!(key)
      return :override if override_raw(definition.key)
      return :env if env_raw(definition).present?

      :default
    end

    def override?(key)
      source(key) == :override
    end

    def write!(key, raw_value)
      definition = definition!(key)
      coerced = coerce(definition, raw_value)
      validate!(definition, coerced)

      record = AppSetting.find_or_initialize_by(key: definition.key.to_s)
      record.value = serialize(definition, coerced)
      record.save!
      bust!(definition.key)
      coerced
    end

    def reset!(key)
      definition = definition!(key)
      AppSetting.where(key: definition.key.to_s).delete_all
      bust!(definition.key)
      get(definition.key)
    end

    def bust!(key = nil)
      if key
        Rails.cache.delete(cache_key(key))
      else
        Admin::SettingsRegistry.settings.each { |setting| Rails.cache.delete(cache_key(setting.key)) }
      end
    end

    def coerce(definition, raw_value)
      case definition.type
      when :boolean
        ActiveModel::Type::Boolean.new.cast(raw_value)
      when :integer
        Integer(raw_value)
      else
        raw_value
      end
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid #{definition.type} for #{definition.key}: #{raw_value.inspect}"
    end

    private

    def definition!(key)
      definition = Admin::SettingsRegistry.setting(key)
      raise UnknownKeyError, "Unknown AppConfig key: #{key.inspect}" unless definition

      definition
    end

    def resolve(definition)
      if (raw = override_raw(definition.key))
        return coerce(definition, deserialize(definition, raw))
      end

      if (raw = env_raw(definition))
        return coerce(definition, raw)
      end

      definition.default
    end

    def override_raw(key)
      AppSetting.find_by(key: key.to_s)&.value
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      # Boot / migrate before the table exists.
      nil
    end

    def env_raw(definition)
      return if definition.env_key.blank?

      value = ENV[definition.env_key]
      return if value.nil?

      stripped = value.to_s.strip
      return if stripped.empty?

      stripped
    end

    def serialize(definition, value)
      case definition.type
      when :boolean then value ? "true" : "false"
      else value.to_s
      end
    end

    def deserialize(definition, raw)
      case definition.type
      when :boolean then raw
      when :integer then Integer(raw)
      else raw
      end
    end

    def validate!(definition, value)
      return unless definition.integer?

      if definition.min && value < definition.min
        raise ArgumentError, "#{definition.key} must be >= #{definition.min}"
      end
      if definition.max && value > definition.max
        raise ArgumentError, "#{definition.key} must be <= #{definition.max}"
      end
    end

    def cached(key)
      Rails.cache.fetch(cache_key(key), expires_in: CACHE_TTL) { yield }
    end

    def cache_key(key)
      "#{CACHE_PREFIX}/#{key}"
    end
  end
end
