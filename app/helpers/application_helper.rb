module ApplicationHelper
  # Prefer persisted display_name when available; otherwise expand USGS
  # abbreviations and title-case (keeping trailing ", WA" state codes).
  def display_location_name(name)
    Usgs::LocationNames.format(name)
  end

  # Absolute URL for Open Graph / Twitter card images.
  def social_image_url
    path = if content_for?(:og_image_path)
      content_for(:og_image_path)
    else
      og_default_path
    end
    "#{app_base_url}#{path}"
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

  def social_title
    content_for?(:title) ? content_for(:title) : "WaterLevels.org"
  end

  def social_description
    if content_for?(:meta_description)
      content_for(:meta_description)
    else
      "Live USGS streamflow, water level, and temperature gauges across the United States."
    end
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
