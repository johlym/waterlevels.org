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
  end
end
