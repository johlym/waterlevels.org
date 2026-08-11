module Usgs
  module StateCodes
    # USGS OGC API `state_code` is the two-digit ANSI/FIPS code.
    # The app stores and routes on USPS abbreviations.
    #
    # National catalog responses also include Mexican states (81–86) and
    # Canadian provinces (90–98). Those are intentionally omitted here; catalog
    # sync skips them via {.try_normalize_postal}.
    #
    # +bbox+ is a padded WGS84 envelope (xmin/ymin/xmax/ymax) used to scope
    # NWPS gauge-list fetches. Values are slightly larger than state borders so
    # near-boundary gauges are not dropped; callers still filter by state.
    STATES = {
      "al" => { fips: "01", name: "Alabama", bbox: { xmin: -88.55, ymin: 30.10, xmax: -84.85, ymax: 35.05 } },
      "ak" => { fips: "02", name: "Alaska", bbox: { xmin: -180.0, ymin: 51.10, xmax: -129.90, ymax: 71.50 } },
      "az" => { fips: "04", name: "Arizona", bbox: { xmin: -114.90, ymin: 31.25, xmax: -108.95, ymax: 37.05 } },
      "ar" => { fips: "05", name: "Arkansas", bbox: { xmin: -94.70, ymin: 32.95, xmax: -89.55, ymax: 36.55 } },
      "ca" => { fips: "06", name: "California", bbox: { xmin: -124.55, ymin: 32.45, xmax: -114.05, ymax: 42.05 } },
      "co" => { fips: "08", name: "Colorado", bbox: { xmin: -109.15, ymin: 36.90, xmax: -101.95, ymax: 41.05 } },
      "ct" => { fips: "09", name: "Connecticut", bbox: { xmin: -73.80, ymin: 40.95, xmax: -71.70, ymax: 42.10 } },
      "de" => { fips: "10", name: "Delaware", bbox: { xmin: -75.85, ymin: 38.40, xmax: -74.95, ymax: 39.90 } },
      "dc" => { fips: "11", name: "District of Columbia", bbox: { xmin: -77.15, ymin: 38.75, xmax: -76.85, ymax: 39.05 } },
      "fl" => { fips: "12", name: "Florida", bbox: { xmin: -87.70, ymin: 24.45, xmax: -79.95, ymax: 31.05 } },
      "ga" => { fips: "13", name: "Georgia", bbox: { xmin: -85.70, ymin: 30.30, xmax: -80.75, ymax: 35.05 } },
      "hi" => { fips: "15", name: "Hawaii", bbox: { xmin: -160.30, ymin: 18.85, xmax: -154.75, ymax: 22.30 } },
      "id" => { fips: "16", name: "Idaho", bbox: { xmin: -117.30, ymin: 41.90, xmax: -110.95, ymax: 49.05 } },
      "il" => { fips: "17", name: "Illinois", bbox: { xmin: -91.60, ymin: 36.90, xmax: -86.95, ymax: 42.55 } },
      "in" => { fips: "18", name: "Indiana", bbox: { xmin: -88.15, ymin: 37.70, xmax: -84.70, ymax: 41.80 } },
      "ia" => { fips: "19", name: "Iowa", bbox: { xmin: -96.70, ymin: 40.30, xmax: -90.05, ymax: 43.55 } },
      "ks" => { fips: "20", name: "Kansas", bbox: { xmin: -102.15, ymin: 36.90, xmax: -94.50, ymax: 40.05 } },
      "ky" => { fips: "21", name: "Kentucky", bbox: { xmin: -89.65, ymin: 36.45, xmax: -81.90, ymax: 39.20 } },
      "la" => { fips: "22", name: "Louisiana", bbox: { xmin: -94.15, ymin: 28.85, xmax: -88.75, ymax: 33.10 } },
      "me" => { fips: "23", name: "Maine", bbox: { xmin: -71.15, ymin: 43.00, xmax: -66.85, ymax: 47.50 } },
      "md" => { fips: "24", name: "Maryland", bbox: { xmin: -79.55, ymin: 37.85, xmax: -74.95, ymax: 39.80 } },
      "ma" => { fips: "25", name: "Massachusetts", bbox: { xmin: -73.55, ymin: 41.20, xmax: -69.85, ymax: 42.95 } },
      "mi" => { fips: "26", name: "Michigan", bbox: { xmin: -90.50, ymin: 41.60, xmax: -82.30, ymax: 48.35 } },
      "mn" => { fips: "27", name: "Minnesota", bbox: { xmin: -97.30, ymin: 43.45, xmax: -89.40, ymax: 49.45 } },
      "ms" => { fips: "28", name: "Mississippi", bbox: { xmin: -91.75, ymin: 30.10, xmax: -88.05, ymax: 35.05 } },
      "mo" => { fips: "29", name: "Missouri", bbox: { xmin: -95.85, ymin: 35.90, xmax: -89.05, ymax: 40.65 } },
      "mt" => { fips: "30", name: "Montana", bbox: { xmin: -116.15, ymin: 44.30, xmax: -103.95, ymax: 49.05 } },
      "ne" => { fips: "31", name: "Nebraska", bbox: { xmin: -104.15, ymin: 39.95, xmax: -95.25, ymax: 43.05 } },
      "nv" => { fips: "32", name: "Nevada", bbox: { xmin: -120.10, ymin: 34.95, xmax: -113.95, ymax: 42.05 } },
      "nh" => { fips: "33", name: "New Hampshire", bbox: { xmin: -72.65, ymin: 42.65, xmax: -70.60, ymax: 45.35 } },
      "nj" => { fips: "34", name: "New Jersey", bbox: { xmin: -75.65, ymin: 38.85, xmax: -73.85, ymax: 41.40 } },
      "nm" => { fips: "35", name: "New Mexico", bbox: { xmin: -109.15, ymin: 31.25, xmax: -102.90, ymax: 37.05 } },
      "ny" => { fips: "36", name: "New York", bbox: { xmin: -79.85, ymin: 40.45, xmax: -71.75, ymax: 45.05 } },
      "nc" => { fips: "37", name: "North Carolina", bbox: { xmin: -84.40, ymin: 33.75, xmax: -75.35, ymax: 36.65 } },
      "nd" => { fips: "38", name: "North Dakota", bbox: { xmin: -104.15, ymin: 45.85, xmax: -96.45, ymax: 49.05 } },
      "oh" => { fips: "39", name: "Ohio", bbox: { xmin: -84.90, ymin: 38.35, xmax: -80.45, ymax: 42.05 } },
      "ok" => { fips: "40", name: "Oklahoma", bbox: { xmin: -103.10, ymin: 33.55, xmax: -94.35, ymax: 37.05 } },
      "or" => { fips: "41", name: "Oregon", bbox: { xmin: -124.65, ymin: 41.90, xmax: -116.35, ymax: 46.35 } },
      "pa" => { fips: "42", name: "Pennsylvania", bbox: { xmin: -80.60, ymin: 39.65, xmax: -74.60, ymax: 42.30 } },
      "ri" => { fips: "44", name: "Rhode Island", bbox: { xmin: -71.95, ymin: 41.10, xmax: -71.05, ymax: 42.05 } },
      "sc" => { fips: "45", name: "South Carolina", bbox: { xmin: -83.45, ymin: 31.95, xmax: -78.45, ymax: 35.25 } },
      "sd" => { fips: "46", name: "South Dakota", bbox: { xmin: -104.15, ymin: 42.40, xmax: -96.35, ymax: 46.00 } },
      "tn" => { fips: "47", name: "Tennessee", bbox: { xmin: -90.40, ymin: 34.90, xmax: -81.55, ymax: 36.75 } },
      "tx" => { fips: "48", name: "Texas", bbox: { xmin: -106.75, ymin: 25.75, xmax: -93.40, ymax: 36.55 } },
      "ut" => { fips: "49", name: "Utah", bbox: { xmin: -114.15, ymin: 36.90, xmax: -108.95, ymax: 42.05 } },
      "vt" => { fips: "50", name: "Vermont", bbox: { xmin: -73.50, ymin: 42.65, xmax: -71.40, ymax: 45.05 } },
      "va" => { fips: "51", name: "Virginia", bbox: { xmin: -83.75, ymin: 36.45, xmax: -75.15, ymax: 39.50 } },
      "wa" => { fips: "53", name: "Washington", bbox: { xmin: -124.90, ymin: 45.45, xmax: -116.80, ymax: 49.05 } },
      "wv" => { fips: "54", name: "West Virginia", bbox: { xmin: -82.75, ymin: 37.15, xmax: -77.65, ymax: 40.70 } },
      "wi" => { fips: "55", name: "Wisconsin", bbox: { xmin: -92.95, ymin: 42.45, xmax: -86.70, ymax: 47.15 } },
      "wy" => { fips: "56", name: "Wyoming", bbox: { xmin: -111.15, ymin: 40.90, xmax: -104.00, ymax: 45.05 } },
      "pr" => { fips: "72", name: "Puerto Rico", bbox: { xmin: -68.05, ymin: 17.85, xmax: -65.15, ymax: 18.55 } },
      "vi" => { fips: "78", name: "United States Virgin Islands", bbox: { xmin: -65.15, ymin: 17.60, xmax: -64.50, ymax: 18.45 } }
    }.freeze

    FIPS_TO_POSTAL = STATES.to_h { |postal, meta| [ meta[:fips], postal ] }.freeze

    module_function

    # Returns a lowercase USPS code for a supported postal or FIPS value, or nil
    # when the code is blank/unsupported (e.g. Canadian province FIPS 95).
    def try_normalize_postal(value)
      code = value.to_s.strip.downcase
      return if code.blank?
      return code if STATES.key?(code)

      FIPS_TO_POSTAL[code]
    end

    def known?(value)
      !try_normalize_postal(value).nil?
    end

    def normalize_postal(value)
      try_normalize_postal(value) ||
        raise(ArgumentError, "Unknown state #{value.inspect}; use a USPS code like WA or FIPS like 53")
    end

    def fips_for(value)
      STATES.fetch(normalize_postal(value)).fetch(:fips)
    end

    def name_for(value)
      STATES.fetch(normalize_postal(value)).fetch(:name)
    end

    # Returns { xmin:, ymin:, xmax:, ymax: } WGS84 envelope for NWPS list calls.
    def bbox_for(value)
      STATES.fetch(normalize_postal(value)).fetch(:bbox)
    end

    def postal_for_fips(fips)
      FIPS_TO_POSTAL[fips.to_s]
    end

    # Returns states whose USPS code equals the query, or whose name equals /
    # starts with the query (case-insensitive). Ordered with exact matches first.
    def match_query(query)
      q = query.to_s.strip.downcase
      return [] if q.length < 2

      matches = STATES.filter_map do |postal, meta|
        name = meta[:name]
        name_key = name.downcase
        score =
          if postal == q || name_key == q
            0
          elsif name_key.start_with?(q)
            1
          end
        next unless score

        { postal: postal, name: name, score: score }
      end

      matches
        .sort_by { |match| [ match[:score], match[:name].length, match[:name] ] }
        .map { |match| match.slice(:postal, :name) }
    end
  end
end
