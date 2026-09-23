# Generates Open Graph share cards (1200×630 PNG) from SVG templates.
# General pages share one branded default; gauge pages include name, site ID,
# and latest measurements.
#
# Station PNGs are not stored in Redis. A 1200×630 card is ~115KB; hashing the
# tip into the cache key left a new copy every hour while the old one lived 24h
# and filled a 250MB Redis (allkeys-lru). The URL stays stable
# (`/og/gauges/:site.png`). Cloudflare holds the card (`s-maxage` 1h) and
# hourly tip/flood syncs purge `og` / `gauge:{site}` / `gauges` so the next
# origin hit rasterizes the new tip. `clear!` only sweeps leftover hashed keys.
class OgImage
  WIDTH = 1200
  HEIGHT = 630
  FONT_DIR = Rails.root.join("vendor/fonts/og")
  DEFAULT_CACHE_KEY = "og_image:v1:default"
  STATION_CACHE_PREFIX = "og_image:v1:station"
  CACHE_TTL = 24.hours

  SERIES_COLORS = {
    "water_level" => "#60a5fa",
    "discharge" => "#22d3ee",
    "temperature" => "#2dd4bf"
  }.freeze

  FLOOD_COLORS = {
    "action" => "#fbbf24",
    "minor" => "#fb923c",
    "moderate" => "#f43f5e",
    "major" => "#ef4444"
  }.freeze

  def self.clear!
    Rails.cache.delete(DEFAULT_CACHE_KEY)
    Rails.cache.delete_matched("#{STATION_CACHE_PREFIX}:*") if Rails.cache.respond_to?(:delete_matched)
  end

  def self.default_png
    Rails.cache.fetch(DEFAULT_CACHE_KEY, expires_in: CACHE_TTL) do
      new(:default).png
    end
  end

  def self.station_png(snapshot)
    snapshot = snapshot.with_indifferent_access
    new(:station, snapshot: snapshot).png
  end

  def initialize(variant, snapshot: nil)
    @variant = variant.to_sym
    @snapshot = snapshot&.with_indifferent_access
  end

  def png
    Rasterizer.to_png(svg)
  end

  def svg
    case @variant
    when :default then default_svg
    when :station then station_svg
    else
      raise ArgumentError, "Unknown OG image variant: #{@variant}"
    end
  end

  private

  def default_svg
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
        #{font_faces}
        #{background_layers}
        #{brand_mark(x: 96, y: 120, size: 72)}
        <text x="192" y="168" font-family="Space Grotesk" font-size="42" font-weight="700" fill="#fafafa" letter-spacing="-0.03em">WaterLevels.org</text>
        <text x="96" y="300" font-family="Space Grotesk" font-size="72" font-weight="700" fill="#fafafa" letter-spacing="-0.04em">Monitor water levels</text>
        <text x="96" y="380" font-family="Space Grotesk" font-size="72" font-weight="700" fill="url(#accentText)" letter-spacing="-0.04em">in real-time</text>
        <text x="96" y="470" font-family="DM Sans" font-size="28" font-weight="500" fill="#a1a1aa">Streamflow · Gauge height · Temperature</text>
        <text x="96" y="520" font-family="DM Sans" font-size="22" font-weight="400" fill="#71717a">Live USGS monitoring across the United States</text>
        #{accent_bar}
      </svg>
    SVG
  end

  def station_svg
    name = truncate(Usgs::LocationNames.format(@snapshot[:name]), 42)
    site_number = @snapshot[:site_number].to_s
    state = @snapshot[:state_code].to_s.upcase
    measurements = Array(@snapshot[:measurements]).first(3)
    flood_category = @snapshot[:flood_category].to_s.presence
    flood_label = @snapshot[:flood_category_label].presence || flood_category&.humanize
    stale = ActiveModel::Type::Boolean.new.cast(@snapshot[:stale])

    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
        #{font_faces}
        #{background_layers}
        #{brand_mark(x: 80, y: 56, size: 48)}
        <text x="148" y="90" font-family="Space Grotesk" font-size="28" font-weight="600" fill="#fafafa" letter-spacing="-0.02em">WaterLevels.org</text>
        <text x="#{WIDTH - 80}" y="90" text-anchor="end" font-family="DM Sans" font-size="22" font-weight="500" fill="#a1a1aa">USGS · #{escape(state)}</text>

        <text x="80" y="210" font-family="Space Grotesk" font-size="52" font-weight="700" fill="#fafafa" letter-spacing="-0.035em">#{escape(name)}</text>
        <text x="80" y="268" font-family="DM Sans" font-size="28" font-weight="500" fill="#71717a">Site #{escape(site_number)}</text>

        #{status_pills(stale: stale, flood_category: flood_category, flood_label: flood_label)}
        #{measurement_cards(measurements)}
        #{accent_bar}
      </svg>
    SVG
  end

  def font_faces
    <<~CSS
      <defs>
        <style type="text/css">
          @font-face {
            font-family: "Space Grotesk";
            src: url("#{font_uri("SpaceGrotesk-Regular.ttf")}");
            font-weight: 400;
          }
          @font-face {
            font-family: "Space Grotesk";
            src: url("#{font_uri("SpaceGrotesk-Medium.ttf")}");
            font-weight: 500;
          }
          @font-face {
            font-family: "Space Grotesk";
            src: url("#{font_uri("SpaceGrotesk-Bold.ttf")}");
            font-weight: 600;
          }
          @font-face {
            font-family: "Space Grotesk";
            src: url("#{font_uri("SpaceGrotesk-Bold.ttf")}");
            font-weight: 700;
          }
          @font-face {
            font-family: "DM Sans";
            src: url("#{font_uri("DMSans-Regular.ttf")}");
            font-weight: 400;
          }
          @font-face {
            font-family: "DM Sans";
            src: url("#{font_uri("DMSans-Medium.ttf")}");
            font-weight: 500;
          }
          @font-face {
            font-family: "DM Sans";
            src: url("#{font_uri("DMSans-SemiBold.ttf")}");
            font-weight: 600;
          }
          @font-face {
            font-family: "DM Sans";
            src: url("#{font_uri("DMSans-Bold.ttf")}");
            font-weight: 700;
          }
        </style>
        <linearGradient id="accentGrad" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#22d3ee"/>
          <stop offset="100%" stop-color="#3b82f6"/>
        </linearGradient>
        <linearGradient id="accentText" x1="0%" y1="0%" x2="100%" y2="0%">
          <stop offset="0%" stop-color="#22d3ee"/>
          <stop offset="100%" stop-color="#60a5fa"/>
        </linearGradient>
        <linearGradient id="accentBar" x1="0%" y1="0%" x2="100%" y2="0%">
          <stop offset="0%" stop-color="#22d3ee"/>
          <stop offset="100%" stop-color="#3b82f6"/>
        </linearGradient>
        <radialGradient id="glowA" cx="20%" cy="30%" r="45%">
          <stop offset="0%" stop-color="#06b6d4" stop-opacity="0.22"/>
          <stop offset="100%" stop-color="#06b6d4" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="glowB" cx="85%" cy="70%" r="40%">
          <stop offset="0%" stop-color="#2563eb" stop-opacity="0.18"/>
          <stop offset="100%" stop-color="#2563eb" stop-opacity="0"/>
        </radialGradient>
      </defs>
    CSS
  end

  def background_layers
    <<~SVG
      <rect width="#{WIDTH}" height="#{HEIGHT}" fill="#09090b"/>
      <rect width="#{WIDTH}" height="#{HEIGHT}" fill="url(#glowA)"/>
      <rect width="#{WIDTH}" height="#{HEIGHT}" fill="url(#glowB)"/>
      <rect x="0" y="0" width="#{WIDTH}" height="#{HEIGHT}" fill="none" stroke="#27272a" stroke-width="2"/>
    SVG
  end

  def brand_mark(x:, y:, size:)
    pad = (size * 0.22).round
    icon = (size * 0.56).round
    <<~SVG
      <rect x="#{x}" y="#{y}" width="#{size}" height="#{size}" rx="#{(size * 0.22).round}" fill="url(#accentGrad)"/>
      <g transform="translate(#{x + pad}, #{y + pad})" fill="#ffffff">
        <path transform="scale(#{format("%.4f", icon / 24.0)})" d="M11.05 1.35h1.95a1.15 1.15 0 0 1 1.15 1.15v19.00a1.15 1.15 0 0 1 -1.15 1.15h-1.95a1.15 1.15 0 0 1 -1.15 -1.15v-19.00a1.15 1.15 0 0 1 1.15 -1.15zM5.85 3.10h3.95a0.50 0.50 0 0 1 0.50 0.50v0.70a0.50 0.50 0 0 1 -0.50 0.50h-3.95a0.50 0.50 0 0 1 -0.50 -0.50v-0.70a0.50 0.50 0 0 1 0.50 -0.50zM7.87 6.50h2.01a0.42 0.42 0 0 1 0.42 0.42v0.51a0.42 0.42 0 0 1 -0.42 0.42h-2.01a0.42 0.42 0 0 1 -0.42 -0.42v-0.51a0.42 0.42 0 0 1 0.42 -0.42zM2.67 9.85h7.01a0.62 0.62 0 0 1 0.62 0.62v1.21a0.62 0.62 0 0 1 -0.62 0.62h-7.01a0.62 0.62 0 0 1 -0.62 -0.62v-1.21a0.62 0.62 0 0 1 0.62 -0.62zM7.87 15.55h2.01a0.42 0.42 0 0 1 0.42 0.42v0.51a0.42 0.42 0 0 1 -0.42 0.42h-2.01a0.42 0.42 0 0 1 -0.42 -0.42v-0.51a0.42 0.42 0 0 1 0.42 -0.42zM5.85 18.60h3.95a0.50 0.50 0 0 1 0.50 0.50v0.70a0.50 0.50 0 0 1 -0.50 0.50h-3.95a0.50 0.50 0 0 1 -0.50 -0.50v-0.70a0.50 0.50 0 0 1 0.50 -0.50zM1.20 11.73L1.46 11.87L1.71 11.94L1.97 11.94L2.23 11.87L2.48 11.73L2.74 11.54L3.00 11.31L3.25 11.06L3.51 10.80L3.77 10.57L4.02 10.37L4.28 10.23L4.54 10.16L4.80 10.16L5.05 10.23L5.31 10.37L5.57 10.56L5.82 10.79L6.08 11.04L6.34 11.30L6.59 11.53L6.85 11.73L6.85 14.53L6.59 14.33L6.34 14.10L6.08 13.84L5.82 13.59L5.57 13.36L5.31 13.17L5.05 13.03L4.80 12.96L4.54 12.96L4.28 13.03L4.02 13.17L3.77 13.37L3.51 13.60L3.25 13.86L3.00 14.11L2.74 14.34L2.48 14.53L2.23 14.67L1.97 14.74L1.71 14.74L1.46 14.67L1.20 14.53ZM13.70 11.70L14.15 11.49L14.59 11.24L15.04 10.97L15.49 10.72L15.94 10.50L16.38 10.35L16.83 10.26L17.28 10.26L17.73 10.34L18.17 10.50L18.62 10.71L19.07 10.96L19.52 11.23L19.96 11.48L20.41 11.70L20.86 11.85L21.31 11.94L21.75 11.94L22.20 11.86L22.65 11.70L22.65 14.40L22.20 14.56L21.75 14.64L21.31 14.64L20.86 14.55L20.41 14.40L19.96 14.18L19.52 13.93L19.07 13.66L18.62 13.41L18.17 13.20L17.73 13.04L17.28 12.96L16.83 12.96L16.38 13.05L15.94 13.20L15.49 13.42L15.04 13.67L14.59 13.94L14.15 14.19L13.70 14.40Z"/>
      </g>
    SVG
  end

  def accent_bar
    %(<rect x="0" y="#{HEIGHT - 8}" width="#{WIDTH}" height="8" fill="url(#accentBar)"/>)
  end

  def status_pills(stale:, flood_category:, flood_label:)
    pills = []
    x = 80

    if stale
      pills << pill(x: x, label: "Stale", fill: "#27272a", text: "#fbbf24", stroke: "#3f3f46")
      x += 110
    else
      pills << pill(x: x, label: "Active", fill: "#052e1c", text: "#34d399", stroke: "#065f46")
      x += 120
    end

    if flood_category.present?
      color = FLOOD_COLORS.fetch(flood_category, "#a1a1aa")
      pills << pill(x: x, label: flood_label.to_s, fill: "#{color}22", text: color, stroke: "#{color}66")
    end

    pills.join("\n")
  end

  def pill(x:, label:, fill:, text:, stroke:)
    width = [ 90, (label.length * 11) + 36 ].max
    <<~SVG
      <rect x="#{x}" y="292" width="#{width}" height="36" rx="18" fill="#{fill}" stroke="#{stroke}" stroke-width="1.5"/>
      <text x="#{x + (width / 2)}" y="316" text-anchor="middle" font-family="DM Sans" font-size="16" font-weight="600" fill="#{text}">#{escape(label)}</text>
    SVG
  end

  def measurement_cards(measurements)
    return empty_measurements_note if measurements.empty?

    cards = measurements.each_with_index.map do |raw, index|
      m = raw.with_indifferent_access
      kind = m[:kind].to_s
      color = SERIES_COLORS.fetch(kind, "#22d3ee")
      label = measurement_label(m)
      value_text, unit_text = format_measurement(m)
      x = 80 + (index * 360)

      <<~SVG
        <rect x="#{x}" y="370" width="336" height="170" rx="20" fill="#18181b" stroke="#27272a" stroke-width="1.5"/>
        <rect x="#{x}" y="370" width="8" height="170" rx="4" fill="#{color}"/>
        <text x="#{x + 28}" y="416" font-family="DM Sans" font-size="20" font-weight="500" fill="#a1a1aa">#{escape(label)}</text>
        <text x="#{x + 28}" y="490" font-family="Space Grotesk" font-size="48" font-weight="700" fill="#fafafa" letter-spacing="-0.03em">#{escape(value_text)}</text>
        <text x="#{x + 28}" y="530" font-family="DM Sans" font-size="22" font-weight="500" fill="#{color}">#{escape(unit_text)}</text>
      SVG
    end

    cards.join("\n")
  end

  def empty_measurements_note
    <<~SVG
      <rect x="80" y="370" width="1040" height="170" rx="20" fill="#18181b" stroke="#27272a" stroke-width="1.5"/>
      <text x="600" y="465" text-anchor="middle" font-family="DM Sans" font-size="28" font-weight="500" fill="#71717a">No recent measurements available</text>
    SVG
  end

  def measurement_label(measurement)
    case measurement[:kind].to_s
    when "water_level" then measurement[:label].presence || "Water level"
    when "discharge" then "Flow"
    when "temperature" then "Temperature"
    else measurement[:label].presence || measurement[:kind].to_s.humanize
    end
  end

  def format_measurement(measurement)
    kind = measurement[:kind].to_s
    value = measurement[:value]
    return [ "—", "" ] if value.nil?

    if kind == "temperature"
      fahrenheit = (value.to_f * 9.0 / 5.0) + 32.0
      return [ format("%.1f", fahrenheit), "°F" ]
    end

    precision = measurement[:precision]
    precision = kind == "discharge" ? 0 : 2 if precision.nil?
    formatted = GaugeValue.format(value, precision: precision.to_i)
    unit = UnitLabel.format(measurement[:unit]).to_s
    [ formatted, unit ]
  end

  def font_uri(filename)
    "file://#{FONT_DIR.join(filename)}"
  end

  def escape(text)
    ERB::Util.html_escape(text.to_s)
  end

  def truncate(text, limit)
    str = text.to_s
    return str if str.length <= limit

    "#{str[0, limit - 1]}…"
  end

  # Shells out to rsvg-convert (librsvg) for SVG → PNG.
  class Rasterizer
    class MissingBinaryError < StandardError; end

    def self.to_png(svg)
      binary = ENV.fetch("RSVG_CONVERT", "rsvg-convert")
      unless system("which", binary, out: File::NULL, err: File::NULL)
        raise MissingBinaryError, "#{binary} not found; install librsvg2-bin to render OG images"
      end

      Tempfile.create([ "og-image", ".svg" ]) do |svg_file|
        svg_file.write(svg)
        svg_file.flush

        Tempfile.create([ "og-image", ".png" ]) do |png_file|
          ok = system(
            binary,
            "--width", WIDTH.to_s,
            "--height", HEIGHT.to_s,
            "--output", png_file.path,
            svg_file.path,
            out: File::NULL,
            err: File::NULL
          )
          raise "rsvg-convert failed to rasterize OG image" unless ok

          File.binread(png_file.path)
        end
      end
    end
  end
end
