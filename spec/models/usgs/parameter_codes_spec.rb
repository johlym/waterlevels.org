require "rails_helper"

RSpec.describe Usgs::ParameterCodes do
  it "prefers NAVD88 reservoir elevation over gage height" do
    expect(described_class.preference_rank("62615")).to be < described_class.preference_rank("00065")
  end

  it "maps temperature and discharge kinds" do
    expect(described_class.measurement_kind_for("00010")).to eq("temperature")
    expect(described_class.measurement_kind_for("00060")).to eq("discharge")
  end
end
