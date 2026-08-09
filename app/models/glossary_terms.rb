# Frozen glossary definitions for UI tooltips on gauge detail pages.
module GlossaryTerms
  # Longer phrases first so "NGVD 1929" wins over "NGVD".
  ENTRIES = [
    {
      term: "NGVD 1929",
      definition: "National Geodetic Vertical Datum of 1929 — a historical U.S. vertical reference used for some elevation measurements."
    },
    {
      term: "NAVD 1988",
      definition: "North American Vertical Datum of 1988 — the current standard vertical reference for elevation in much of the U.S."
    },
    {
      term: "NGVD",
      definition: "National Geodetic Vertical Datum — a historical U.S. vertical reference surface for elevation measurements."
    },
    {
      term: "NAVD",
      definition: "North American Vertical Datum — a modern U.S. vertical reference surface for elevation measurements."
    },
    {
      term: "Provisional",
      definition: "USGS real-time data that has not finished review. Values can be revised, corrected, or removed after approval."
    },
    {
      term: "datum",
      definition: "A reference surface from which water heights or elevations are measured. Local datums are site-specific; NGVD and NAVD are national standards."
    },
    {
      term: "Action stage",
      definition: "NWS threshold where water is near bankfull and agencies begin preparedness actions."
    },
    {
      term: "Minor flood",
      definition: "NWS flood category for minimal or no property damage, but possibly some public threat."
    },
    {
      term: "Moderate flood",
      definition: "NWS flood category for some inundation of structures and roads near streams."
    },
    {
      term: "Major flood",
      definition: "NWS flood category for extensive inundation, significant evacuations, and/or property damage."
    },
    {
      term: "Flood stage",
      definition: "The water-surface elevation where a river begins to overflow its banks and produce flooding impacts."
    }
  ].freeze

  PATTERN = Regexp.new(
    ENTRIES.map { |entry| Regexp.escape(entry[:term]) }.join("|")
  ).freeze

  DEFINITIONS = ENTRIES.to_h { |entry| [ entry[:term], entry[:definition] ] }.freeze

  module_function

  def definition_for(term)
    DEFINITIONS[term.to_s]
  end
end
