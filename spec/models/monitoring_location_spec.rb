require "rails_helper"

RSpec.describe MonitoringLocation, type: :model do
  it { is_expected.to validate_presence_of(:site_number) }
  it { is_expected.to validate_presence_of(:name) }

  describe "#stale?" do
    it "is stale when observation is older than one week" do
      location = build(:monitoring_location, latest_observed_at: 8.days.ago)
      expect(location).to be_stale
    end

    it "is not stale when recently observed" do
      location = build(:monitoring_location, latest_observed_at: 1.hour.ago)
      expect(location).not_to be_stale
    end
  end

  describe ".ordered_for_state_table" do
    it "sorts by county then name" do
      b = create(:monitoring_location, site_number: "1", usgs_monitoring_location_id: "USGS-1", county_name: "Benton", name: "Zebra")
      a = create(:monitoring_location, site_number: "2", usgs_monitoring_location_id: "USGS-2", county_name: "Adams", name: "Alpha")
      c = create(:monitoring_location, site_number: "3", usgs_monitoring_location_id: "USGS-3", county_name: "Adams", name: "Beta")

      expect(described_class.ordered_for_state_table).to eq([a, c, b])
    end
  end
end
