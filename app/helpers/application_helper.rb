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

  private

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
