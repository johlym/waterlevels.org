module Usgs
  module StateCodes
    # USGS OGC API `state_code` is the two-digit ANSI/FIPS code.
    # The app stores and routes on USPS abbreviations.
    STATES = {
      "al" => { fips: "01", name: "Alabama" },
      "ak" => { fips: "02", name: "Alaska" },
      "az" => { fips: "04", name: "Arizona" },
      "ar" => { fips: "05", name: "Arkansas" },
      "ca" => { fips: "06", name: "California" },
      "co" => { fips: "08", name: "Colorado" },
      "ct" => { fips: "09", name: "Connecticut" },
      "de" => { fips: "10", name: "Delaware" },
      "dc" => { fips: "11", name: "District of Columbia" },
      "fl" => { fips: "12", name: "Florida" },
      "ga" => { fips: "13", name: "Georgia" },
      "hi" => { fips: "15", name: "Hawaii" },
      "id" => { fips: "16", name: "Idaho" },
      "il" => { fips: "17", name: "Illinois" },
      "in" => { fips: "18", name: "Indiana" },
      "ia" => { fips: "19", name: "Iowa" },
      "ks" => { fips: "20", name: "Kansas" },
      "ky" => { fips: "21", name: "Kentucky" },
      "la" => { fips: "22", name: "Louisiana" },
      "me" => { fips: "23", name: "Maine" },
      "md" => { fips: "24", name: "Maryland" },
      "ma" => { fips: "25", name: "Massachusetts" },
      "mi" => { fips: "26", name: "Michigan" },
      "mn" => { fips: "27", name: "Minnesota" },
      "ms" => { fips: "28", name: "Mississippi" },
      "mo" => { fips: "29", name: "Missouri" },
      "mt" => { fips: "30", name: "Montana" },
      "ne" => { fips: "31", name: "Nebraska" },
      "nv" => { fips: "32", name: "Nevada" },
      "nh" => { fips: "33", name: "New Hampshire" },
      "nj" => { fips: "34", name: "New Jersey" },
      "nm" => { fips: "35", name: "New Mexico" },
      "ny" => { fips: "36", name: "New York" },
      "nc" => { fips: "37", name: "North Carolina" },
      "nd" => { fips: "38", name: "North Dakota" },
      "oh" => { fips: "39", name: "Ohio" },
      "ok" => { fips: "40", name: "Oklahoma" },
      "or" => { fips: "41", name: "Oregon" },
      "pa" => { fips: "42", name: "Pennsylvania" },
      "ri" => { fips: "44", name: "Rhode Island" },
      "sc" => { fips: "45", name: "South Carolina" },
      "sd" => { fips: "46", name: "South Dakota" },
      "tn" => { fips: "47", name: "Tennessee" },
      "tx" => { fips: "48", name: "Texas" },
      "ut" => { fips: "49", name: "Utah" },
      "vt" => { fips: "50", name: "Vermont" },
      "va" => { fips: "51", name: "Virginia" },
      "wa" => { fips: "53", name: "Washington" },
      "wv" => { fips: "54", name: "West Virginia" },
      "wi" => { fips: "55", name: "Wisconsin" },
      "wy" => { fips: "56", name: "Wyoming" },
      "pr" => { fips: "72", name: "Puerto Rico" },
      "vi" => { fips: "78", name: "United States Virgin Islands" }
    }.freeze

    FIPS_TO_POSTAL = STATES.to_h { |postal, meta| [ meta[:fips], postal ] }.freeze

    module_function

    def normalize_postal(value)
      code = value.to_s.strip.downcase
      return code if STATES.key?(code)
      return FIPS_TO_POSTAL[code] if FIPS_TO_POSTAL.key?(code)

      raise ArgumentError, "Unknown state #{value.inspect}; use a USPS code like WA or FIPS like 53"
    end

    def fips_for(value)
      STATES.fetch(normalize_postal(value)).fetch(:fips)
    end

    def name_for(value)
      STATES.fetch(normalize_postal(value)).fetch(:name)
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
