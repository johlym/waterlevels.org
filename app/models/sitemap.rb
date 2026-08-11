require "cgi"

class Sitemap
  PREFIX = "sitemap:v1".freeze
  TTL = 24.hours
  STATIC_PATHS = %w[/ /map /alerts /about /disclosures /faq /privacy /terms].freeze
  SITEMAP_NS = "http://www.sitemaps.org/schemas/sitemap/0.9".freeze

  class << self
    def index_xml(host:, protocol: "https")
      fetch("index") { build_index(host: host, protocol: protocol) }
    end

    def static_xml(host:, protocol: "https")
      fetch("static") { build_static(host: host, protocol: protocol) }
    end

    def state_xml(state_code, host:, protocol: "https")
      code = state_code.to_s.downcase
      fetch("state:#{code}") { build_state(code, host: host, protocol: protocol) }
    end

    def key_for(suffix)
      "#{PREFIX}:#{suffix}"
    end

    def clear!
      Rails.cache.delete_matched("#{PREFIX}:*") if Rails.cache.respond_to?(:delete_matched)
    end

    private

    def fetch(suffix)
      key = key_for(suffix)
      cached = Rails.cache.read(key)
      return cached if cached.present?

      xml = yield
      Rails.cache.write(key, xml, expires_in: TTL)
      xml
    end

    def build_index(host:, protocol:)
      base = absolute_base(host, protocol)
      locs = [ "#{base}/sitemaps/static.xml" ]
      Usgs::StateCodes::STATES.each_key do |code|
        locs << "#{base}/sitemaps/#{code}.xml"
      end

      +<<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="#{SITEMAP_NS}">
        #{locs.map { |loc| sitemap_entry(loc) }.join}
        </sitemapindex>
      XML
    end

    def build_static(host:, protocol:)
      base = absolute_base(host, protocol)
      entries = STATIC_PATHS.map { |path| url_entry("#{base}#{path}") }
      urlset(entries)
    end

    def build_state(state_code, host:, protocol:)
      base = absolute_base(host, protocol)
      gauge_entries = []
      max_observed = nil

      MonitoringLocation.in_state(state_code)
        .select(:id, :site_number, :slug, :state_code, :latest_observed_at)
        .find_each do |loc|
          observed = loc.latest_observed_at
          max_observed = [ max_observed, observed ].compact.max
          gauge_entries << url_entry("#{base}/gauges/#{loc.path_state}/#{loc.to_param}", observed)
        end

      entries = [ url_entry("#{base}/gauges/#{state_code}", max_observed) ] + gauge_entries
      urlset(entries)
    end

    def absolute_base(host, protocol)
      "#{protocol}://#{host}"
    end

    def urlset(entries)
      +<<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="#{SITEMAP_NS}">
        #{entries.join}
        </urlset>
      XML
    end

    def sitemap_entry(loc)
      <<~XML
        <sitemap>
          <loc>#{escape(loc)}</loc>
        </sitemap>
      XML
    end

    def url_entry(loc, lastmod = nil)
      lines = [ "<url>", "  <loc>#{escape(loc)}</loc>" ]
      lines << "  <lastmod>#{lastmod.utc.xmlschema}</lastmod>" if lastmod
      lines << "</url>"
      "#{lines.join("\n")}\n"
    end

    def escape(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
