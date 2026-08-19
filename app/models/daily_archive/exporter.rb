module DailyArchive
  class Exporter
    DEFAULT_BATCH = 50

    def initialize(store: DailyArchive.store, batch_size: DEFAULT_BATCH, progress: nil, writer: nil)
      @store = store
      @batch_size = batch_size
      @progress = progress
      @writer = writer || Writer.new(store: store)
    end

    def perform(time_series_ids: nil, only_cold: false)
      raise Cloudflare::R2Client::Error, "R2 store disabled" unless @store.enabled?

      checkpoint = ExportCheckpoint.resume_or_start!(
        only_cold: only_cold,
        time_series_ids: time_series_ids
      )
      if checkpoint.resumed
        @progress&.step(
          "resuming export after_series_id=#{checkpoint.after_series_id} " \
          "series=#{checkpoint.series} points=#{checkpoint.points}"
        )
      end

      scope = TimeSeries.order(:id).where("id > ?", checkpoint.after_series_id)
      if time_series_ids.present?
        scope = scope.where(id: time_series_ids)
      else
        # Catch-up export only needs leftover Postgres dailies — skip the rest
        # of the fleet so scheduled drains stay cheap after the table is empty.
        scope = scope.where(id: DailyObservation.select(:time_series_id).distinct)
      end

      exported_series = checkpoint.series
      exported_points = checkpoint.points
      daily_deleted = 0
      drain = Drain.new(store: @store, progress: @progress)

      scope.find_in_batches(batch_size: @batch_size) do |batch|
        batch.each do |series|
          relation = series.daily_observations.order(:observed_on)
          # only_cold: settled calendar days (legacy leftover drain), not "today".
          relation = relation.where("observed_on < ?", Date.current) if only_cold
          unless relation.exists?
            checkpoint.mark_series!(series.id, exported_points: 0, exported_series: 0)
            next
          end

          begin
            count = @writer.upsert_from_daily_observations(
              time_series_id: series.id,
              relation: relation
            )
          rescue Writer::LockBusyError => e
            # Leave the cursor before this series so a retry re-attempts it.
            @progress&.step("series=#{series.id} lock busy: #{e.message}")
            raise
          end

          # Shuttle succeeded — drop the same leftover rows now instead of
          # waiting for the nightly retention pass.
          deleted = drain.delete_exported!(relation)
          daily_deleted += deleted

          exported_series += 1
          exported_points += count
          checkpoint.mark_series!(series.id, exported_points: count, exported_series: 1)
          @progress&.step("series=#{series.id} points=#{count} daily_deleted=#{deleted}")
        end
      end

      checkpoint.clear!

      vacuum = TableMaintenance.vacuum_after_deletes!(
        daily_deleted: daily_deleted,
        progress: @progress
      )

      Telemetry.add_attributes(
        "app.operation" => "daily_archive.export",
        "app.series_count" => exported_series,
        "app.observation_count" => exported_points,
        "app.daily_deleted" => daily_deleted,
        "app.vacuumed" => vacuum[:vacuumed]
      ) if defined?(Telemetry)

      {
        series: exported_series,
        points: exported_points,
        daily_deleted: daily_deleted,
        vacuumed: vacuum[:vacuumed],
        vacuum_tables: vacuum[:tables],
        vacuum_ms: vacuum[:duration_ms]
      }
    end
  end
end
