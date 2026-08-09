module Nwps
  # Geographic slices for NWPS `GET /gauges` list calls.
  #
  # NWPS rate-limits at ~10 requests / 5 minutes, and the unbounded national
  # list often 504s. Ten slices keep list traffic at the quota ceiling while
  # staying small enough for the API to answer.
  module ListRegions
    # Seven west→east CONUS longitude bands, plus AK / HI / PR+VI.
    # +states+ lists USPS codes used to decide which slices a single-state
    # sync must fetch; border states may appear in more than one band.
    REGIONS = {
      "conus_pacific" => {
        bbox: { xmin: -125.5, ymin: 32.4, xmax: -116.0, ymax: 49.2 },
        states: %w[wa or ca nv]
      },
      "conus_intermountain" => {
        bbox: { xmin: -116.0, ymin: 31.2, xmax: -108.0, ymax: 49.2 },
        states: %w[nv id ut az mt wy co nm]
      },
      "conus_rockies_high_plains" => {
        bbox: { xmin: -108.0, ymin: 25.7, xmax: -100.0, ymax: 49.2 },
        states: %w[mt wy co nm nd sd ne ks ok tx]
      },
      "conus_central" => {
        bbox: { xmin: -100.0, ymin: 25.7, xmax: -92.0, ymax: 49.2 },
        states: %w[nd sd ne ks ok tx mn ia mo ar la]
      },
      "conus_midwest_south" => {
        bbox: { xmin: -92.0, ymin: 24.4, xmax: -84.0, ymax: 49.2 },
        states: %w[mn ia mo ar la wi il ms tn al ky in mi oh fl ga]
      },
      "conus_appalachia_se" => {
        bbox: { xmin: -84.0, ymin: 24.4, xmax: -76.0, ymax: 47.5 },
        states: %w[mi oh ky tn al ga fl sc nc va wv pa ny md dc de nj]
      },
      "conus_northeast" => {
        bbox: { xmin: -76.0, ymin: 36.5, xmax: -66.5, ymax: 47.5 },
        states: %w[pa ny nj md dc de ct ri ma vt nh me va]
      },
      "alaska" => {
        bbox: { xmin: -180.0, ymin: 51.1, xmax: -129.9, ymax: 71.5 },
        states: %w[ak]
      },
      "hawaii" => {
        bbox: { xmin: -160.3, ymin: 18.8, xmax: -154.7, ymax: 22.3 },
        states: %w[hi]
      },
      "puerto_rico" => {
        bbox: { xmin: -68.1, ymin: 17.6, xmax: -64.5, ymax: 18.6 },
        states: %w[pr vi]
      }
    }.freeze

    STATE_TO_REGION_IDS = REGIONS.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(id, meta), memo|
      meta.fetch(:states).each { |postal| memo[postal] << id }
    end.transform_values(&:freeze).freeze

    module_function

    def ids
      REGIONS.keys
    end

    def fetch(region_id)
      REGIONS.fetch(region_id.to_s) do
        raise ArgumentError, "Unknown NWPS list region #{region_id.inspect}"
      end
    end

    def bbox_for(region_id)
      fetch(region_id).fetch(:bbox)
    end

    # Regions a state-scoped sync must request (may be more than one when a
    # state sits on a band boundary).
    def ids_covering_state(state)
      postal = Usgs::StateCodes.normalize_postal(state)
      ids = STATE_TO_REGION_IDS[postal]
      raise ArgumentError, "No NWPS list region covers state #{postal.inspect}" if ids.blank?

      ids
    end
  end
end
