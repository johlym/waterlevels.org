module ApplicationHelper
  # USGS names arrive in ALL CAPS; present them in title case while keeping
  # trailing 2-letter state abbreviations uppercase (e.g. ", WA").
  def display_location_name(name)
    titleized = name.to_s.titleize
    titleized.gsub(/,\s*([A-Za-z]{2})\z/) { ", #{$1.upcase}" }
  end

  # e.g. "August 1, 2026 at 09:30:00 PM"
  def display_timestamp(value)
    time = coerce_time(value)
    return "—" if time.blank?

    time.in_time_zone.strftime("%B %-d, %Y at %I:%M:%S %p")
  end

  # e.g. "Latitude 30°15'11\" N, Longitude 97°44'37\" W"
  def format_coordinates_dms(latitude, longitude)
    lat = latitude.to_f
    lon = longitude.to_f
    "Latitude #{degrees_to_dms(lat, "N", "S")}, Longitude #{degrees_to_dms(lon, "E", "W")}"
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
