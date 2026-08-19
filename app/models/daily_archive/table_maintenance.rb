module DailyArchive
  # Reclaim dead tuples after archive shuttle / IV prune. DELETE only marks
  # rows dead; Postgres will not shrink or refresh planner stats until VACUUM
  # (ANALYZE). Autovacuum eventually catches up, but a fleet-wide handoff can
  # leave millions of dead tuples for hours — so we VACUUM the tables we just
  # drained when this run (or leftover n_dead_tup) crosses the threshold.
  #
  # Never VACUUM FULL (exclusive rewrite). Skip inside the test env — Rails
  # wraps examples in a transaction and VACUUM cannot run there.
  class TableMaintenance
    TABLES = {
      daily: "daily_observations",
      continuous: "continuous_observations"
    }.freeze

    class << self
      def vacuum_enabled?
        AppConfig.boolean?(:daily_archive_vacuum)
      end

      def min_deleted
        AppConfig.integer(:daily_archive_vacuum_min_deleted)
      end

      def vacuum_after_deletes!(daily_deleted: 0, continuous_deleted: 0, progress: nil, dead_tuples: nil)
        tables = tables_to_vacuum(
          daily_deleted: daily_deleted,
          continuous_deleted: continuous_deleted,
          dead_tuples: dead_tuples
        )
        return skip_result("none") if tables.empty?

        vacuum!(tables, progress: progress)
      end

      def tables_to_vacuum(daily_deleted: 0, continuous_deleted: 0, dead_tuples: nil)
        threshold = min_deleted
        [
          [ TABLES[:daily], daily_deleted ],
          [ TABLES[:continuous], continuous_deleted ]
        ].filter_map do |name, deleted|
          dead = if dead_tuples
            dead_tuples[name].to_i
          else
            dead_tuple_count(name)
          end
          name if needs_vacuum?(deleted.to_i, dead, threshold)
        end
      end

      def dead_tuple_count(table_name)
        connection.select_value(
          "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = #{connection.quote(table_name)}"
        ).to_i
      rescue ActiveRecord::StatementInvalid
        0
      end

      def vacuum!(tables, progress: nil, force: false)
        return skip_result("test") if Rails.env.test? && !force
        return skip_result("disabled") unless vacuum_enabled?
        return skip_result("empty") if tables.empty?

        quoted = tables.map { |name| connection.quote_table_name(name) }.join(", ")
        previous_timeout = connection.select_value("SHOW statement_timeout")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        connection.execute("SET statement_timeout TO 0")
        connection.execute("VACUUM (ANALYZE) #{quoted}")
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        progress&.step("postgres vacuum tables=#{tables.join(",")} duration_ms=#{duration_ms}")
        Rails.logger.info(
          "[DailyArchive::TableMaintenance] vacuum tables=#{tables.join(",")} duration_ms=#{duration_ms}"
        )
        { vacuumed: true, tables: tables, duration_ms: duration_ms }
      rescue StandardError => e
        Rails.logger.warn("[DailyArchive::TableMaintenance] vacuum failed: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        { vacuumed: false, tables: tables, duration_ms: 0, error: e.message }
      ensure
        restore_statement_timeout(previous_timeout) if previous_timeout
      end

      private

      def needs_vacuum?(deleted, dead, threshold)
        if threshold.zero?
          deleted.positive? || dead.positive?
        else
          deleted >= threshold || dead >= threshold
        end
      end

      def skip_result(reason)
        { vacuumed: false, tables: [], duration_ms: 0, skipped: reason }
      end

      def restore_statement_timeout(previous)
        connection.execute("SET statement_timeout TO #{connection.quote(previous)}")
      rescue StandardError => e
        Rails.logger.warn("[DailyArchive::TableMaintenance] restore statement_timeout failed: #{e.message}")
      end

      def connection
        ActiveRecord::Base.connection
      end
    end
  end
end
