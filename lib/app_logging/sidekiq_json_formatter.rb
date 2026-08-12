# frozen_string_literal: true

require "sidekiq/logger"

module AppLogging
  # Sidekiq's default Pretty/WithoutTimestamp formatters emit lines like:
  #   INFO  pid=2 tid=a0y jid=… class=EdgeCachePurgeJob elapsed=0.003: done
  #   INFO  pid=2 tid=ab6: queueing AdminDashboardCountersJob (admin_dashboard_counters)
  # Match the AppLogging JSON shape instead, flattening Sidekiq::Context.
  class SidekiqJsonFormatter < Sidekiq::Logger::Formatters::Base
    def call(severity, _time, _program_name, message)
      AppLogging.event(payload(severity, message)) << "\n"
    end

    private

    def payload(severity, message)
      text = message.to_s
      fields = {
        level: severity.to_s.downcase,
        event: "sidekiq",
        message: text,
        pid: ::Process.pid,
        tid: tid
      }
      merge_context!(fields)
      annotate_message!(fields, text)
      fields
    end

    def merge_context!(fields)
      Sidekiq::Context.current.each do |key, value|
        next if value.nil?

        case key.to_sym
        when :class
          fields[:job] = value
        when :jid, :elapsed
          fields[key.to_sym] = value
        else
          fields[key.to_sym] = value unless fields.key?(key.to_sym)
        end
      end
    end

    def annotate_message!(fields, text)
      if (match = text.match(/\Aqueueing (\S+) \(([^)]+)\)\z/))
        fields[:event] = "sidekiq.enqueue"
        fields[:job] ||= match[1]
        fields[:schedule] = match[2]
      elsif %w[start done fail].include?(text)
        fields[:event] = "sidekiq.job"
        fields[:status] = text
      end
    end
  end
end
