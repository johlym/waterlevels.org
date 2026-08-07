module DailyArchive
  class Exporter
    DEFAULT_BATCH = 50

    def initialize(store: DailyArchive.store, batch_size: DEFAULT_BATCH, progress: nil)
      @store = store
      @batch_size = batch_size
      @progress = progress
      @writer = Writer.new(store: store)
    end

    def perform(time_series_ids: nil, only_cold: false)
      raise Cloudflare::R2Client::Error, "R2 store disabled" unless @store.enabled?

      scope = TimeSeries.order(:id)
      scope = scope.where(id: time_series_ids) if time_series_ids.present?

      exported_series = 0
      exported_points = 0

      scope.find_in_batches(batch_size: @batch_size) do |batch|
        batch.each do |series|
          relation = series.daily_observations.order(:observed_on)
          relation = relation.where("observed_on < ?", DailyArchive.hot_cutoff_on) if only_cold
          next if relation.none?

          count = @writer.upsert_from_daily_observations(time_series_id: series.id, relation: relation)
          exported_series += 1
          exported_points += count
          @progress&.step("series=#{series.id} points=#{count}")
        end
      end

      Telemetry.add_attributes(
        "app.operation" => "daily_archive.export",
        "app.series_count" => exported_series,
        "app.observation_count" => exported_points
      ) if defined?(Telemetry)

      { series: exported_series, points: exported_points }
    end
  end
end
