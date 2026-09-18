require "test_helper"

class ProviderHistoryBackfillJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  test "history jobs wait when sync has not inserted the location yet" do
    assert_enqueued_with(job: CdecHistoryBackfillJob, args: [ "cdecoro", 3 ]) do
      CdecHistoryBackfillJob.perform_now("cdecoro", 3)
    end

    assert_enqueued_with(job: UsbrHistoryBackfillJob, args: [ "usbr3514", 3 ]) do
      UsbrHistoryBackfillJob.perform_now("usbr3514", 3)
    end

    assert_enqueued_with(job: UsaceHistoryBackfillJob, args: [ "usacenabraystown", 3 ]) do
      UsaceHistoryBackfillJob.perform_now("usacenabraystown", 3)
    end

    assert_enqueued_with(job: NwpsHistoryBackfillJob, args: [ "nwpsacrw1" ]) do
      NwpsHistoryBackfillJob.perform_now("nwpsacrw1")
    end
  end

  test "history jobs still reject a location from the wrong provider" do
    create(
      :monitoring_location,
      site_number: "cdecoro",
      data_provider: DataProviders::USGS,
      provider_location_id: "USGS-cdecoro"
    )

    error = assert_raises(ArgumentError) do
      CdecHistoryBackfillJob.perform_now("cdecoro", 3)
    end
    assert_equal "not a CDEC location", error.message
  end
end
