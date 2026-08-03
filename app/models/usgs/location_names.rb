module Usgs
  # Expands common USGS station-name abbreviations and title-cases the result
  # for display / search. Raw USGS `monitoring_location_name` values stay stored
  # separately as the source of truth.
  module LocationNames
    # Whole-token expansions only (matched case-insensitively on word boundaries).
    # Keep this list conservative — prefer missing an expansion over false positives.
    ABBREVIATIONS = {
      "lk" => "Lake",
      "rv" => "River",
      "r" => "River",
      "ck" => "Creek",
      "cr" => "Creek",
      "crk" => "Creek",
      "nr" => "near",
      "abv" => "above",
      "blw" => "below",
      "fk" => "Fork",
      "br" => "Branch",
      "res" => "Reservoir",
      "spg" => "Spring",
      "spgs" => "Springs",
      "trib" => "Tributary",
      "hwy" => "Highway",
      "rr" => "Railroad",
      "byp" => "Bypass",
      "div" => "Diversion",
      "cnfl" => "Confluence",
      "nf" => "North Fork",
      "sf" => "South Fork",
      "ef" => "East Fork",
      "wf" => "West Fork"
    }.freeze

    TOKEN_PATTERN = /\b[A-Za-z]+\b/

    module_function

    # Expanded, title-cased name for UI surfaces.
    # "LK TRAVIS NR AUSTIN, TX" → "Lake Travis Near Austin, TX"
    # "Nueces Rv nr Three Rivers, TX" → "Nueces River Near Three Rivers, TX"
    def format(name)
      raw = name.to_s.strip
      return "" if raw.blank?

      expanded = expand(raw)
      titleize_preserving_state(expanded)
    end

    # Lowercase expanded form used for ILIKE search matching.
    def search_key(name)
      format(name).downcase
    end

    def expand(name)
      name.to_s.gsub(TOKEN_PATTERN) do |token|
        ABBREVIATIONS.fetch(token.downcase, token)
      end
    end

    def titleize_preserving_state(name)
      titleized = name.to_s.titleize
      titleized.gsub(/,\s*([A-Za-z]{2})\z/) { ", #{$1.upcase}" }
    end
  end
end
