# Search-snippet helpers. Gauge titles have to fit the ~60 characters Google
# shows as the blue link; longer titles get cut mid-word (the live
# "Cambridge Reservoir., Unnamed Tributary…" title was displaying as
# "Cambridge Reservoir - Unnamed Tribute").
module Seo
  GAUGE_TITLE_LIMIT = 60
  DESCRIPTION_LIMIT = 160

  LOCALITY = /,?\s+(?:Near|At|Above|Below)\s+[^,]+\z/i

  KIND_LABELS = {
    "water_level" => "water level",
    "discharge" => "flow",
    "temperature" => "temperature"
  }.freeze

  module_function

  def gauge_title(name:, state_code:, kinds: nil)
    state = state_code.to_s.upcase
    place = strip_state_suffix(name.to_s.strip, state)
    labels = preferred_labels(kinds)
    labels.each_with_index do |label, index|
      suffix = title_suffix(label, state)
      fitted = place_that_fits(place, suffix, GAUGE_TITLE_LIMIT)
      next if word_chopped?(place, fitted) && index < labels.length - 1

      return "#{fitted}#{suffix}".strip
    end
  end

  def gauge_description(name:, agency:, county_name: nil, state_name: nil, kinds: nil)
    subject = series_phrase(kinds)
    place = name.to_s.strip
    prefix = "Current #{subject} for "
    agency_suffix = " from #{agency} monitoring data."
    where_options = [
      [ county_name, state_name ],
      [ state_name ],
      []
    ]
    where_options.each do |bits|
      where = location_clause(bits)
      text = "#{prefix}#{place}#{where}#{agency_suffix}"
      return text if text.length <= DESCRIPTION_LIMIT
    end

    budget = DESCRIPTION_LIMIT - prefix.length - agency_suffix.length
    "#{prefix}#{place_that_fits(place, "", budget)}#{agency_suffix}"
  end

  def breadcrumb_list(crumbs)
    {
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => crumbs.each_with_index.map { |(name, url), index|
        item = { "@type" => "ListItem", "position" => index + 1, "name" => name }
        item["item"] = url if url.present?
        item
      }
    }
  end

  def website(name:, url:, description:)
    {
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => name,
      "url" => url,
      "description" => description
    }
  end

  def strip_state_suffix(name, state)
    return name if state.blank?

    name.sub(/,\s*#{Regexp.escape(state)}\z/i, "").strip
  end

  def preferred_labels(kinds)
    set = Array(kinds).map(&:to_s)
    if set.include?("water_level") && set.include?("discharge")
      [ "Water Level & Flow", "Water Level" ]
    elsif set.include?("water_level") || set.empty?
      [ "Water Level" ]
    elsif set.include?("discharge")
      [ "Streamflow" ]
    elsif set.include?("temperature")
      [ "Water Temperature" ]
    else
      [ "Water Level" ]
    end
  end

  def series_phrase(kinds)
    labels = %w[water_level discharge temperature].filter_map { |kind|
      KIND_LABELS[kind] if Array(kinds).map(&:to_s).include?(kind)
    }
    labels = [ "water level" ] if labels.empty?
    case labels.length
    when 1 then labels.first
    when 2 then "#{labels[0]} and #{labels[1]}"
    else "#{labels[0..-2].join(", ")}, and #{labels[-1]}"
    end
  end

  def title_suffix(label, state)
    state.present? ? " #{label} | #{state}" : " #{label}"
  end

  def place_that_fits(place, suffix, limit)
    return place if place.length + suffix.length <= limit

    shortened = drop_locality(place)
    if shortened.present? && shortened.length + suffix.length <= limit
      return shortened
    end

    budget = limit - suffix.length
    truncate_at_word(shortened.presence || place, budget)
  end

  def drop_locality(place)
    place.to_s.sub(LOCALITY, "").strip
  end

  def word_chopped?(place, fitted)
    fitted != place && fitted != drop_locality(place)
  end

  def truncate_at_word(text, budget)
    return "" if budget <= 0
    return text if text.length <= budget

    kept = []
    text.split(/\s+/).each do |word|
      candidate = (kept + [ word ]).join(" ")
      break if candidate.length > budget

      kept << word
    end
    result = kept.join(" ").sub(/[,\-–—]\z/, "").strip
    result.presence || text[0, budget].strip
  end

  def location_clause(bits)
    names = Array(bits).map { |bit| bit.to_s.strip }.reject(&:blank?)
    return "" if names.empty?

    " in #{names.join(", ")}"
  end
end
