require "test_helper"

class States::LocationsTableComponentTest < ViewComponent::TestCase
  test "exposes alert helpers when locations have flood alerts" do
    locations = [
      { name: "Quiet Creek", flood_alert: false, county_name: "King" },
      { name: "Flood Creek", flood_alert: true, county_name: "King" }
    ]

    component = States::LocationsTableComponent.new(locations: locations)

    assert component.any_alerts?
    assert_equal 1, component.alert_count
    assert_equal [ locations.last ], component.alert_locations
  end

  test "reports no alerts when none are present" do
    locations = [
      { name: "Quiet Creek", flood_alert: false, county_name: "King" }
    ]

    component = States::LocationsTableComponent.new(locations: locations)

    assert_not component.any_alerts?
    assert_equal 0, component.alert_count
  end

  test "renders alerts filter only when alerts exist" do
    with_alerts = render_inline(
      States::LocationsTableComponent.new(
        locations: [ { name: "Flood Creek", flood_alert: true, county_name: "King", path: "/gauges/wa/1", site_number: "1" } ]
      )
    )

    assert_includes with_alerts.to_html, "Stations with alerts"
    assert_includes with_alerts.to_html, 'data-state-directory-target="alertsOnly"'
    assert_includes with_alerts.to_html, 'data-alert="true"'

    without_alerts = render_inline(
      States::LocationsTableComponent.new(
        locations: [ { name: "Quiet Creek", flood_alert: false, county_name: "King", path: "/gauges/wa/2", site_number: "2" } ]
      )
    )

    assert_not_includes without_alerts.to_html, "Stations with alerts"
    assert_not_includes without_alerts.to_html, 'data-state-directory-target="alertsOnly"'
    assert_includes without_alerts.to_html, 'data-alert="false"'
  end

  test "groups by state and hides alerts filter when configured for alerts page" do
    locations = [
      { name: "Flood Creek", flood_alert: true, county_name: "King", state_code: "wa", state_name: "Washington", path: "/gauges/wa/1", site_number: "1" },
      { name: "Major River", flood_alert: true, county_name: "Travis", state_code: "tx", state_name: "Texas", path: "/gauges/tx/2", site_number: "2" }
    ]

    html = render_inline(
      States::LocationsTableComponent.new(locations: locations, group_by: :state, show_alerts_filter: false)
    ).to_html

    assert_includes html, "Quick state jump"
    assert_not_includes html, "Quick county jump"
    assert_includes html, "Washington"
    assert_includes html, "Texas"
    assert_not_includes html, "Stations with alerts"
    assert_not_includes html, "Flood stages"
    assert_operator html.index("Texas"), :<, html.index("Washington")
  end

  test "renders flood stage filters above measurement types when enabled" do
    locations = [
      {
        name: "Flood Creek",
        flood_alert: true,
        flood_category: "action",
        county_name: "King",
        state_code: "wa",
        state_name: "Washington",
        path: "/gauges/wa/1",
        site_number: "1"
      },
      {
        name: "Major River",
        flood_alert: true,
        flood_category: "major",
        county_name: "Travis",
        state_code: "tx",
        state_name: "Texas",
        path: "/gauges/tx/2",
        site_number: "2"
      }
    ]

    html = render_inline(
      States::LocationsTableComponent.new(
        locations: locations,
        group_by: :state,
        show_alerts_filter: false,
        show_flood_stages_filter: true
      )
    ).to_html

    assert_includes html, "Flood stages"
    assert_includes html, 'data-state-directory-target="floodStage"'
    assert_includes html, "Action Stage"
    assert_includes html, "Minor Flooding"
    assert_includes html, "Moderate Flooding"
    assert_includes html, "Major Flooding"
    assert_includes html, 'data-flood-stage="action"'
    assert_includes html, 'data-flood-stage="major"'
    assert_operator html.index("Flood stages"), :<, html.index("Measurement types")
  end
end
