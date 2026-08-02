require "test_helper"

module Usgs
  class ParameterCodesTest < ActiveSupport::TestCase
    test "prefers NAVD88 reservoir elevation over gage height" do
      assert_operator ParameterCodes.preference_rank("62615"), :<, ParameterCodes.preference_rank("00065")
    end

    test "maps temperature and discharge kinds" do
      assert_equal "temperature", ParameterCodes.measurement_kind_for("00010")
      assert_equal "discharge", ParameterCodes.measurement_kind_for("00060")
    end
  end
end
