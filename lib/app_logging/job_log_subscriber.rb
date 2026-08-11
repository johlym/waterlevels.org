require "active_support/log_subscriber"

module AppLogging
  # Lograge-style single-line ActiveJob lifecycle logs.
  #
  #   event=job.enqueue job=FloodStageSyncJob jid=… queue=sync adapter=Sidekiq
  #   event=job.perform job=FloodStageSyncJob jid=… queue=sync status=ok duration=12.34
  class JobLogSubscriber < ActiveSupport::LogSubscriber
    def enqueue(event)
      log_lifecycle("job.enqueue", event)
    end
    subscribe_log_level :enqueue, :info

    def enqueue_at(event)
      data = lifecycle_data("job.enqueue_at", event)
      data[:at] = scheduled_at(event)
      emit(data)
    end
    subscribe_log_level :enqueue_at, :info

    def enqueue_all(event)
      jobs = event.payload[:jobs] || []
      enqueued = event.payload[:enqueued_count].to_i
      info do
        AppLogging.key_value(
          event: "job.enqueue_all",
          adapter: adapter_name(event),
          count: jobs.size,
          enqueued: enqueued,
          failed: jobs.size - enqueued
        )
      end
    end
    subscribe_log_level :enqueue_all, :info

    # Skip perform_start — perform already carries duration + status.

    def perform(event)
      log_lifecycle("job.perform", event)
    end
    subscribe_log_level :perform, :info

    def enqueue_retry(event)
      job = event.payload[:job]
      error = event.payload[:error]
      data = {
        event: "job.retry",
        job: job.class.name,
        jid: job.job_id,
        queue: job.queue_name,
        executions: job.executions,
        wait: event.payload[:wait].to_i
      }
      data[:error] = "#{error.class}: #{error.message}" if error
      info { AppLogging.key_value(data) }
    end
    subscribe_log_level :enqueue_retry, :info

    def retry_stopped(event)
      job = event.payload[:job]
      error = event.payload[:error]
      error_line(
        event: "job.retry_stopped",
        job: job.class.name,
        jid: job.job_id,
        queue: job.queue_name,
        executions: job.executions,
        error: error && "#{error.class}: #{error.message}"
      )
    end
    subscribe_log_level :retry_stopped, :error

    def discard(event)
      job = event.payload[:job]
      error = event.payload[:error]
      error_line(
        event: "job.discard",
        job: job.class.name,
        jid: job.job_id,
        queue: job.queue_name,
        error: error && "#{error.class}: #{error.message}"
      )
    end
    subscribe_log_level :discard, :error

    private

    def log_lifecycle(name, event)
      emit(lifecycle_data(name, event))
    end

    def lifecycle_data(name, event)
      job = event.payload[:job]
      data = {
        event: name,
        job: job.class.name,
        jid: job.job_id,
        queue: job.queue_name,
        adapter: adapter_name(event)
      }

      if name == "job.perform"
        data[:duration] = event.duration.to_f.round(2)
      end

      data[:status] = event_status(name, event)

      if (error = event_error(event))
        data[:error] = error
      end

      if job.class.log_arguments? && job.arguments.any?
        data[:args] = format_args(job.arguments)
      end

      data.compact
    end

    def event_status(name, event)
      if event.payload[:exception_object] || event.payload[:exception]
        "error"
      elsif event.payload[:aborted]
        "aborted"
      elsif name.start_with?("job.enqueue") && (event.payload[:job].enqueue_error rescue nil)
        "error"
      else
        "ok"
      end
    end

    def event_error(event)
      if (error = event.payload[:exception_object])
        "#{error.class}: #{error.message}"
      elsif (error = event.payload[:exception]).is_a?(Array)
        "#{error[0]}: #{error[1]}"
      elsif (error = event.payload[:job]&.enqueue_error)
        "#{error.class}: #{error.message}"
      end
    end

    def emit(data)
      line = AppLogging.key_value(data)
      if data[:status] == "error" || data[:status] == "aborted"
        error { line }
      else
        info { line }
      end
    end

    def error_line(data)
      error { AppLogging.key_value(data.compact) }
    end

    def adapter_name(event)
      ActiveJob.adapter_name(event.payload[:adapter])
    rescue StandardError
      event.payload[:adapter].class.name.demodulize
    end

    def scheduled_at(event)
      Time.at(event.payload[:job].scheduled_at).utc.iso8601
    rescue StandardError
      nil
    end

    def format_args(arguments)
      arguments.map { |arg| format_arg(arg) }
    end

    def format_arg(arg)
      case arg
      when Hash
        arg.transform_values { |value| format_arg(value) }
      when Array
        arg.map { |value| format_arg(value) }
      when GlobalID::Identification
        arg.to_global_id.to_s rescue arg.to_s
      else
        arg
      end
    end

    def logger
      ActiveJob::Base.logger
    end
  end
end
