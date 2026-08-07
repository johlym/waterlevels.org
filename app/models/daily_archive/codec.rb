require "json"
require "zlib"
require "stringio"

module DailyArchive
  module Codec
    module_function

    def encode(points)
      sorted = normalize_points(points).sort_by { |p| p.fetch("d") }
      json = JSON.generate(sorted)
      buffer = StringIO.new
      buffer.set_encoding(Encoding::BINARY)
      gz = Zlib::GzipWriter.new(buffer)
      gz.write(json)
      gz.close
      buffer.string.force_encoding(Encoding::BINARY)
    end

    def decode(body)
      return [] if body.blank?

      binary = body.to_s.b
      json = Zlib::GzipReader.new(StringIO.new(binary)).read
      Array(JSON.parse(json)).map { |row| normalize_point(row) }.compact
    end

    # Merge by date. USGS always wins over derived; newer USGS replaces older USGS.
    def merge(existing, incoming)
      by_day = {}
      normalize_points(existing).each { |p| by_day[p["d"]] = p }
      normalize_points(incoming).each do |point|
        day = point["d"]
        prior = by_day[day]
        if prior.nil?
          by_day[day] = point
        elsif point["s"] == DailyArchive::SOURCE_USGS
          by_day[day] = point
        elsif prior["s"] != DailyArchive::SOURCE_USGS
          by_day[day] = point
        end
      end
      by_day.values.sort_by { |p| p["d"] }
    end

    def source_mix(points)
      sources = normalize_points(points).map { |p| p["s"] }.uniq
      if sources.include?(DailyArchive::SOURCE_USGS) && sources.include?(DailyArchive::SOURCE_DERIVED)
        "both"
      elsif sources.include?(DailyArchive::SOURCE_DERIVED)
        "derived"
      else
        "usgs"
      end
    end

    def normalize_points(points)
      Array(points).filter_map { |p| normalize_point(p) }
    end

    def normalize_point(row)
      hash = row.respond_to?(:with_indifferent_access) ? row.with_indifferent_access : row
      day = (hash["d"] || hash[:d] || hash["observed_on"] || hash[:observed_on]).to_s
      value = hash["v"] || hash[:v] || hash["value"] || hash[:value]
      return if day.blank? || value.nil?

      source = (hash["s"] || hash[:s] || hash["source"] || hash[:source] || DailyArchive::SOURCE_USGS).to_s
      source = DailyArchive::SOURCE_USGS unless source == DailyArchive::SOURCE_DERIVED
      point = { "d" => day, "v" => value.to_f, "s" => source }
      approval = hash["a"] || hash[:a] || hash["approval_status"] || hash[:approval_status]
      point["a"] = approval.to_s if approval.present?
      point
    end
  end
end
