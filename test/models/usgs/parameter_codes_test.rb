require "test_helper"

module Usgs
  class ParameterCodesTest < ActiveSupport::TestCase
    test "prefers gage height over reservoir elevation datums" do
      assert_operator ParameterCodes.preference_rank("00065"), :<, ParameterCodes.preference_rank("62614")
      assert_operator ParameterCodes.preference_rank("00065"), :<, ParameterCodes.preference_rank("62615")
    end

    test "labels water level variants" do
      assert_equal "Gage height", ParameterCodes.label_for("00065")
      assert_equal "Elevation (NGVD 1929)", ParameterCodes.label_for("62614")
    end

    test "maps temperature and discharge kinds" do
      assert_equal "temperature", ParameterCodes.measurement_kind_for("00010")
      assert_equal "discharge", ParameterCodes.measurement_kind_for("00060")
    end

    test "rejects USGS temperature fault sentinels that overflow decimal(8,3)" do
      assert ParameterCodes.plausible_temperature_c?(18.6)
      assert ParameterCodes.plausible_temperature_c?("0.1")
      assert ParameterCodes.plausible_temperature_c?(-2)
      refute ParameterCodes.plausible_temperature_c?(-100_000)
      refute ParameterCodes.plausible_temperature_c?("-100000")
      refute ParameterCodes.plausible_temperature_c?(100_000)
      refute ParameterCodes.plausible_temperature_c?(nil)
      refute ParameterCodes.plausible_temperature_c?("")
    end
  end
end
