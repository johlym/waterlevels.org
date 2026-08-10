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

    assert_includes html, "+50 ft³/s"
    assert_includes html, "-100 ft³/s"
    assert_includes html, "High 5,000"
    assert_includes html, "Low 200"
    assert_not_includes html, "data-temp-delta-c"
    assert_not_includes html, "temperature-unit#setF"
  end
end
