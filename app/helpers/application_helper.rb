module ApplicationHelper
  # Prefer persisted display_name when available; otherwise expand USGS
  # abbreviations and title-case (keeping trailing ", WA" state codes).
  def display_location_name(name)
    Usgs::LocationNames.format(name)
  end

  # Absolute URL for the default Open Graph / Twitter card image.
  def social_image_url
    absolute_url(og_default_path)
  end

  def site_icon_tags
    [
      { href: "/icon-48.png", sizes: "48x48", type: "image/png" },
      { href: "/icon.svg", type: "image/svg+xml" }
    ]
  end

  # Defaults rendered by the meta-tags gem. Page views override title,
  # description, and the station card image with set_meta_tags.
  def public_meta_tags
    image = social_image_url
    {
      site: "WaterLevels.org",
      reverse: true,
      description: "Live USGS streamflow, water level, and temperature gauges across the United States.",
      canonical: social_page_url,
      icon: site_icon_tags,
      og: {
        site_name: "WaterLevels.org",
        type: "website",
        url: social_page_url,
        title: :full_title,
        description: :description,
        image: { _: image, width: 1200, height: 630, type: "image/png" }
      },
      twitter: {
        card: "summary_large_image",
        title: :full_title,
        description: :description,
        image: image
      }
    }
  end

  def app_base_url
    if !Rails.env.local? && ENV["APP_HOST"].present?
      "https://#{ENV["APP_HOST"]}"
    else
      request.base_url
    end
  end

  def social_page_url
    "#{app_base_url}#{request.path}"
  end

  def absolute_url(path)
    return if path.blank?
    return path if path.match?(%r{\Ahttps?://})

    "#{app_base_url}#{path}"
  end

  def json_ld_tag(data)
    tag.script(ERB::Util.json_escape(data.to_json).html_safe, type: "application/ld+json")
  end

  def breadcrumb_json_ld(crumbs)
    Seo.breadcrumb_list(crumbs.map { |name, path| [ name, absolute_url(path) ] })
  end

  # Ancestors match the visible gauge breadcrumb. The station is the current
  # page, so search results can show "Massachusetts › Middlesex" instead of
  # the URL slug.
  def gauge_breadcrumbs(snapshot, location_name)
    crumbs = [ [ "Map", root_path ] ]
    state = snapshot[:state_name].presence || snapshot[:state_code].to_s.upcase
    crumbs << [ state, state_gauges_path(snapshot[:state_code]) ]
    if snapshot[:county_name].present?
      county = display_county_name(snapshot[:county_name])
      crumbs << [ county, state_gauges_path(snapshot[:state_code], anchor: directory_group_anchor(county)) ]
    end
    crumbs << [ location_name, request.path ]
    crumbs
  end

  # Breadcrumbs / headings should not repeat the word "County".
  def display_county_name(name)
    name.to_s.gsub(/\s+County\z/i, "").strip
  end

  # Fragment id for county/state group sections on directory pages.
  def directory_group_anchor(name)
    name.to_s.parameterize.presence || "unspecified"
  end

  # e.g. "August 1, 2026 at 09:30:00 PM CDT" in the station's local zone when known.
  def display_timestamp(value, time_zone: nil, state_code: nil)
    time = coerce_time(value)
    return "—" if time.blank?

    zone = Usgs::TimeZones.resolve(time_zone, state_code: state_code)
    local = zone ? time.in_time_zone(zone) : time.in_time_zone
    formatted = local.strftime("%B %-d, %Y at %I:%M:%S %p")
    abbreviation = local.strftime("%Z")
    abbreviation.present? ? "#{formatted} #{abbreviation}" : formatted
  end

  # e.g. "Latitude 30°15'11\" N, Longitude 97°44'37\" W"
  def format_coordinates_dms(latitude, longitude)
    lat = latitude.to_f
    lon = longitude.to_f
    "Latitude #{degrees_to_dms(lat, "N", "S")}, Longitude #{degrees_to_dms(lon, "E", "W")}"
  end

  # e.g. "ft3/s" / "ft^3/s" → "ft³/s"
  def display_unit(unit)
    UnitLabel.format(unit)
  end

  # e.g. 541.10 / 540 — pad fractional gauge readings to +precision+ places.
  def display_gauge_value(value, precision: 2)
    GaugeValue.format(value, precision: precision)
  end

  # Server-render a default temperature so no-JS / first paint is not blank.
  # JS (temperature-unit controller) replaces this with the cookie preference.
  def display_temperature_c(celsius, signed: false, hide_unit: false)
    return if celsius.nil?

    unit = cookies[:temperature_unit].to_s == "c" ? "c" : "f"
    c = celsius.to_f
    value = unit == "c" ? c : (c * 9.0 / 5.0 + 32.0)
    formatted = format("%.1f", value)
    formatted = "+#{formatted}" if signed && value.positive?
    hide_unit ? formatted : "#{formatted} °#{unit == "c" ? "C" : "F"}"
  end

  def display_temperature_delta_c(delta_c)
    return if delta_c.nil?

    unit = cookies[:temperature_unit].to_s == "c" ? "c" : "f"
    c = delta_c.to_f
    value = unit == "c" ? c : (c * 9.0 / 5.0)
    formatted = format("%+.1f", value)
    "#{formatted} °#{unit == "c" ? "C" : "F"}"
  end

  # e.g. +1,234.50 / -12
  def signed_number(value, precision:)
    return if value.nil?

    formatted = display_gauge_value(value, precision: precision)
    value.to_f.positive? ? "+#{formatted}" : formatted
  end

  # Wrap known glossary terms (datum, NGVD, NAVD, Provisional, …) in CSS tooltips.
  # Set focusable: false inside buttons so we do not nest focus targets.
  def annotate_glossary_terms(text, focusable: true)
    source = text.to_s
    return "".html_safe if source.blank?

    parts = []
    cursor = 0
    source.scan(GlossaryTerms::PATTERN) do
      match = Regexp.last_match
      parts << ERB::Util.html_escape(source[cursor...match.begin(0)])
      parts << glossary_term_span(match[0], focusable: focusable)
      cursor = match.end(0)
    end
    parts << ERB::Util.html_escape(source[cursor..])
    safe_join(parts)
  end

  private

  def glossary_term_span(term, focusable:)
    definition = GlossaryTerms.definition_for(term)
    return ERB::Util.html_escape(term) if definition.blank?

    tag.span(class: "term-tip", tabindex: (focusable ? 0 : nil)) do
      safe_join(
        [
          ERB::Util.html_escape(term),
          tag.span(definition, class: "term-tip-bubble", role: "tooltip")
        ]
      )
    end
  end

  def degrees_to_dms(value, positive_hemisphere, negative_hemisphere)
    absolute = value.abs
    degrees = absolute.floor
    minutes_float = (absolute - degrees) * 60
    minutes = minutes_float.floor
    seconds = ((minutes_float - minutes) * 60).round
    if seconds == 60
      seconds = 0
      minutes += 1
    end
    if minutes == 60
      minutes = 0
      degrees += 1
    end
    hemisphere = value >= 0 ? positive_hemisphere : negative_hemisphere
    "#{degrees}°#{minutes}'#{seconds}\" #{hemisphere}"
  end


  def coerce_time(value)
    case value
    when Time, ActiveSupport::TimeWithZone, DateTime then value
    when Date then value.in_time_zone.beginning_of_day
    when String then Time.zone.parse(value)
    end
  rescue ArgumentError, TypeError
    nil
  end
end
