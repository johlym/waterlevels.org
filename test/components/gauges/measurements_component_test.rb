require "test_helper"

class Gauges::MeasurementsComponentTest < ViewComponent::TestCase
  test "temperature trends emit client-convertible celsius data attributes" do
    html = render_inline(
      Gauges::MeasurementsComponent.new(
        measurements: [
          {
            kind: "temperature",
            label: "Temperature",
            value: 12.0,
            unit: "deg C",
            parameter_code: "00010",
            precision: 2,
            trends: { change_24h: 1.0, yoy: -2.5 },
            extremes: {
              high: { value: 18.0 },
              low: { value: 6.0 }
            }
          }
        ]
      )
    ).to_html

    assert_includes html, 'data-temp-c="12.0"'
    assert_includes html, 'data-temp-delta-c="1.0"'
    assert_includes html, 'data-temp-delta-c="-2.5"'
    assert_includes html, 'data-temp-c="18.0"'
    assert_includes html, 'data-temp-c="6.0"'
    assert_includes html, 'data-temp-hide-unit="true"'
    assert_includes html, "temperature-unit#setF"
    assert_includes html, "temperature-unit#setC"

    # Must not server-render °C trend values that ignore the F/C preference.
    assert_not_includes html, "+1.00 deg C"
    assert_not_includes html, "-2.50 deg C"
    assert_not_includes html, "+1.00 °C"
    assert_not_includes html, "High 18.00"
    assert_not_includes html, "Low 6.00"
  end

  test "non-temperature trends remain server-rendered" do
    html = render_inline(
      Gauges::MeasurementsComponent.new(
        measurements: [
          {
            kind: "discharge",
            label: "Discharge",
            value: 1200,
            unit: "ft3/s",
            parameter_code: "00060",
            precision: 0,
            trends: { change_24h: 50, yoy: -100 },
            extremes: {
              high: { value: 5000 },
              low: { value: 200 }
            }
          }
        ]
      )
    ).to_html

    assert_includes html, "+50"
    assert_includes html, "ft³/s"
    assert_includes html, "-100"
    assert_includes html, ">High<"
    assert_includes html, ">5,000<"
    assert_includes html, ">Low<"
    assert_includes html, ">200<"
    assert_not_includes html, "High 5,000 ·"
    assert_not_includes html, "· Low"
    assert_not_includes html, "data-temp-delta-c"
    assert_not_includes html, "temperature-unit#setF"
    assert_not_includes html, "water year"
  end

  test "discharge shows the 24h percent and the peak water year" do
    html = render_inline(
      Gauges::MeasurementsComponent.new(
        measurements: [
          {
            kind: "discharge",
            label: "Discharge",
            value: 1200,
            unit: "ft3/s",
            parameter_code: "00060",
            precision: 0,
            trends: { change_24h: 50, change_24h_percent: 4.2, yoy: nil },
            extremes: {
              high: { value: 5000, water_year: 2011 },
              low: { value: 200 }
            },
            peak: {
              margin: -3800,
              water_year: 2011,
              year_min: 1990,
              year_max: 2011,
              year_count: 22,
              record: false
            }
          }
        ]
      )
    ).to_html

    assert_includes html, "+50"
    assert_includes html, "ft³/s"
    assert_includes html, "(+4.2%)"
    assert_includes html, "water year 2011"
    assert_includes html, ">3,800<"
    assert_includes html, "below the water year 2011 peak"
    assert_includes html, 'class="stat-meta">water year 2011'
    assert_includes html, 'class="peak-caption">below the water year 2011 peak'
    assert_not_includes html, "· water year"
    assert_not_includes html, "· Low"
  end

  test "a qualifying peak margin is called a record and a short history is not" do
    html = render_inline(
      Gauges::MeasurementsComponent.new(
        measurements: [
          {
            kind: "water_level",
            label: "Gage height",
            value: 12.4,
            unit: "ft",
            parameter_code: "00065",
            precision: 2,
            trends: { change_24h: nil },
            extremes: { high: { value: 12.0, water_year: 2009 }, low: nil },
            peak: {
              margin: 0.4,
              water_year: 2009,
              year_min: 2000,
              year_max: 2009,
              year_count: 10,
              record: true
            }
          },
          {
            kind: "water_level",
            label: "Gage height",
            value: 8.4,
            unit: "ft",
            parameter_code: "00062",
            precision: 2,
            trends: {},
            extremes: { high: { value: 8.0, water_year: 2011 }, low: nil },
            peak: {
              margin: 0.4,
              water_year: 2011,
              year_min: 2011,
              year_max: 2011,
              year_count: 1,
              record: false
            }
          }
        ]
      )
    ).to_html

    assert_includes html, ">0.40<"
    assert_includes html, "New high"
    assert_includes html, "above every annual peak on file (2000–2009)"
    assert_includes html, "above the water year 2011 peak"
    assert_includes html, "peak-note--record"
    assert_not_includes html, "above every annual peak on file (2011–2011)"
  end

  test "featured mention links back to the homepage list" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(
      TrendHighlights::CACHE_KEY,
      {
        stage_movers: [ { site_number: "12101000" } ],
        discharge_movers: [],
        records: []
      }
    )

    html = render_inline(
      Gauges::MeasurementsComponent.new(
        site_number: "12101000",
        measurements: [
          {
            kind: "water_level",
            label: "Gage height",
            value: 4,
            unit: "ft",
            parameter_code: "00065",
            precision: 2,
            trends: {},
            extremes: {}
          }
        ]
      )
    ).to_html

    assert_includes html, "Featured in today's rising stations"
    assert_includes html, 'href="/#rising-fastest"'
  ensure
    Rails.cache = previous_cache
  end
end
