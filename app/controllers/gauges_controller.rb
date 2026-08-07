class GaugesController < ApplicationController
  include CacheableResponse

  def show
    @location = find_location!
    ensure_canonical_path!(@location)
    @snapshot = StationSnapshotCache.fetch(@location)
    enqueued = false
    if @location.needs_history_backfill?
      enqueued = HistoryBackfillJob.enqueue(@location.id)
    end
    Telemetry.add_attributes(
      "station.site_number" => @location.site_number,
      "usgs.state" => @location.state_code,
      "backfill.enqueued" => enqueued
    )
    cache_public!(tags: [ "gauge:#{@location.site_number}" ])
  end

  private

  def find_location!
    site_number = if params[:site_number_slug].present?
      params[:site_number_slug].to_s.split("-", 2).first
    else
      params[:site_number].to_s
    end
    location = MonitoringLocation.find_by!(site_number: site_number)
    if params[:state].present? && location.state_code != params[:state].to_s.downcase
      raise ActiveRecord::RecordNotFound
    end
    location
  end

  def ensure_canonical_path!(location)
    expected = "/gauges/#{location.path_state}/#{location.to_param}"
    return if request.path == expected

    redirect_to expected, status: :moved_permanently
  end
end
