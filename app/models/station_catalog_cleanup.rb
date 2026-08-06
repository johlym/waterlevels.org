# Audits and removes catalog rows that should not remain in the product DB.
#
# Typical errant rows after a broad sync:
# - non water-body site types (wells, atmosphere, etc.)
# - locations with no selected measurement series
# - locations with no discharge / stage / temperature flags
# - locations that never received an observation
#
# Dry-run by default; pass apply: true (or APPLY=1 via the rake task) to delete.
class StationCatalogCleanup
  Category = Data.define(:key, :label, :ids)

  CATEGORIES = [
    [ :non_water_body, "Non water-body site types" ],
    [ :no_measurements, "No discharge, stage, or temperature" ],
    [ :no_selected_series, "No selected time series" ],
    [ :never_observed, "Never observed" ]
  ].freeze

  class << self
    def audit(state: nil)
      new(state: state).audit
    end

    def purge!(state: nil, apply: false)
      new(state: state).purge!(apply: apply)
    end
  end

  def initialize(state: nil)
    @state = state.presence
  end

  def audit
    {
      total: scope.count,
      categories: categories.map { |category| summarize(category) }
    }
  end

  def purge!(apply: false)
    removable_ids = categories.flat_map(&:ids).uniq
    report = {
      dry_run: !apply,
      total_before: scope.count,
      removable: removable_ids.size,
      categories: categories.map { |category| summarize(category) },
      deleted: 0,
      total_after: nil
    }

    return report unless apply
    return report if removable_ids.empty?

    deleted = MonitoringLocation.purge_ids!(removable_ids)
    NearbyStations.refresh_all
    StateListingCache.warm_all
    AlertsListingCache.warm
    EdgeCacheInvalidation.after_catalog_sync!(state: @state)

    report.merge(
      deleted: deleted,
      total_after: scope.count
    )
  end

  private

  def postal_code
    @postal_code ||= @state && Usgs::StateCodes.normalize_postal(@state)
  end

  def scope
    postal_code ? MonitoringLocation.in_state(postal_code) : MonitoringLocation.all
  end

  def categories
    @categories ||= CATEGORIES.filter_map do |key, label|
      ids = send(:"#{key}_ids")
      next if ids.empty?

      Category.new(key: key, label: label, ids: ids)
    end
  end

  def summarize(category)
    {
      key: category.key,
      label: category.label,
      count: category.ids.size,
      sample_site_numbers: scope.where(id: category.ids).limit(8).pluck(:site_number)
    }
  end

  def non_water_body_ids
    scope
      .where("COALESCE(UPPER(site_type_code), '') NOT IN (?)", Usgs::SiteTypes::WATER_BODY)
      .pluck(:id)
  end

  def no_measurements_ids
    scope
      .where(has_water_level: false, has_discharge: false, has_temperature: false)
      .pluck(:id)
  end

  def no_selected_series_ids
    selected = TimeSeries.selected.select(:monitoring_location_id)
    scope.where.not(id: selected).pluck(:id)
  end

  def never_observed_ids
    scope.where(latest_observed_at: nil).pluck(:id)
  end
end
