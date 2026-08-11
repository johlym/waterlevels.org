# Persisted admin overrides for registered AppConfig keys.
# Absence of a row means "use ENV (if declared) then code default".
class AppSetting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, presence: true

  after_commit :bust_app_config_cache

  private

  def bust_app_config_cache
    AppConfig.bust!(key)
  end
end
