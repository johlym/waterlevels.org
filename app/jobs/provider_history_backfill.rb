# History backfill is enqueued alongside the matching sync job. The location
# row does not exist until sync finishes, so a missing site is a short wait
# rather than a RecordNotFound that fills the Sidekiq retry set.
module ProviderHistoryBackfill
  class NotReady < StandardError; end

  extend ActiveSupport::Concern

  WAIT = 30.seconds
  ATTEMPTS = 10

  included do
    retry_on NotReady, wait: WAIT, attempts: ATTEMPTS do |job, error|
      Rails.logger.warn("#{job.class.name} stopped waiting for location: #{error.message}")
    end
  end

  private

  def require_synced_location!(site_number)
    location = MonitoringLocation.find_by(site_number: site_number)
    raise NotReady, "site=#{site_number} not synced yet" unless location

    location
  end
end
