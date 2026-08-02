require "rails_helper"

RSpec.describe "Gauges", type: :request do
  let!(:location) { create(:monitoring_location) }

  it "renders the canonical gauge page" do
    get "/gauges/#{location.state_code}/#{location.to_param}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(location.name)
    expect(response.headers["Cache-Tag"]).to include("gauge:#{location.site_number}")
  end

  it "renders state listing sorted by county then name" do
    create(:monitoring_location, site_number: "100", usgs_monitoring_location_id: "USGS-100", county_name: "Yakima", name: "Z River", state_code: "wa")
    create(:monitoring_location, site_number: "101", usgs_monitoring_location_id: "USGS-101", county_name: "Adams", name: "A Creek", state_code: "wa")

    get "/gauges/wa"
    expect(response).to have_http_status(:ok)
    expect(response.body.index("A Creek")).to be < response.body.index("Z River")
  end

  it "returns map stations for a bbox" do
    get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["stations"]).to be_an(Array)
  end
end
