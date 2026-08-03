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

      # Capture acronyms from the raw name before expand() introduces mixed case
      # (e.g. "LK" → "Lake"), which would otherwise leave place words looking
      # like acronyms.
      acronyms = extract_acronyms(raw)
      expanded = expand(raw)
      titleize_preserving_state(expanded, acronyms: acronyms)
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

    def titleize_preserving_state(name, acronyms: [])
      titleized = name.to_s.titleize
      Array(acronyms).each do |acronym|
        titleized = titleized.sub(/\b#{Regexp.escape(acronym.titleize)}\b/, acronym)
      end
      titleized.gsub(/,\s*([A-Za-z]{2})\z/) { ", #{$1.upcase}" }
    end

    # Preserve agency-style tokens (LCRA, TCEQQW) that would otherwise become
    # "Lcra" / "Tceqqw" after titleize. Skip when the whole name is shouting
    # (typical USGS all-caps names) so place words still titleize normally.
    def extract_acronyms(name)
      raw = name.to_s
      letters = raw.gsub(/[^A-Za-z]/, "")
      return [] if letters.blank? || letters == letters.upcase

      raw.scan(/\b[A-Z]{3,}[A-Z0-9]*\b/)
    end
  end
end
