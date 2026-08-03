module ApplicationHelper
  # Prefer persisted display_name when available; otherwise expand USGS
  # abbreviations and title-case (keeping trailing ", WA" state codes).
  def display_location_name(name)
    Usgs::LocationNames.format(name)
  end

  # Breadcrumbs / headings should not repeat the word "County".
  def display_county_name(name)
    name.to_s.gsub(/\s+County\z/i, "").strip
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

  # e.g. +1,234.50 / -12
  def signed_number(value, precision:)
    return if value.nil?

    formatted = number_with_precision(value, precision: precision, delimiter: ",")
    value.to_f.positive? ? "+#{formatted}" : formatted
  end

  private

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
