class StationWatch < ApplicationRecord
  belongs_to :subscriber
  belongs_to :monitoring_location
  has_many :alert_rules, dependent: :destroy

  validates :monitoring_location_id, uniqueness: { scope: :subscriber_id }

  after_create :ensure_default_rules!, :reset_watched_locations_cache
  after_destroy :reset_watched_locations_cache

  def ensure_default_rules!
    alert_rules.find_or_create_by!(kind: "flood_category_change") do |rule|
      rule.params = { "notify_clear" => true, "min_severity" => "action" }
    end
    alert_rules.find_or_create_by!(kind: "digest") do |rule|
      rule.params = { "include" => true }
    end
  end

  def rule_for(kind)
    alert_rules.find_by(kind: kind)
  end

  private

  def reset_watched_locations_cache
    Alerts::WatchedLocations.reset!
  end
end
