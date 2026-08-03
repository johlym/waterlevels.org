require "test_helper"

module Usgs
  class TimeZonesTest < ActiveSupport::TestCase
    test "maps common USGS abbreviations to IANA identifiers" do
      assert_equal "America/Chicago", TimeZones.iana_identifier("CST")
      assert_equal "America/Chicago", TimeZones.iana_identifier("cdt")
      assert_equal "America/New_York", TimeZones.iana_identifier("EST")
      assert_equal "America/Los_Angeles", TimeZones.iana_identifier("PST")
      assert_equal "America/Anchorage", TimeZones.iana_identifier("AKST")
      assert_equal "Pacific/Honolulu", TimeZones.iana_identifier("HST")
    end

    test "maps Arizona MST to Phoenix instead of Denver" do
      assert_equal "America/Phoenix", TimeZones.iana_identifier("MST", state_code: "az")
      assert_equal "America/Denver", TimeZones.iana_identifier("MST", state_code: "co")
      assert_equal "America/Denver", TimeZones.iana_identifier("MDT", state_code: "az")
    end

    test "passes through valid IANA names" do
      assert_equal "America/Chicago", TimeZones.iana_identifier("America/Chicago")
    end

    test "resolve returns an ActiveSupport time zone" do
      zone = TimeZones.resolve("CST")
      assert_kind_of ActiveSupport::TimeZone, zone
      assert_equal "America/Chicago", zone.tzinfo.name
    end

    test "returns nil for blank or unknown abbreviations" do
      assert_nil TimeZones.iana_identifier(nil)
      assert_nil TimeZones.iana_identifier("")
      assert_nil TimeZones.iana_identifier("XYZ")
      assert_nil TimeZones.resolve("XYZ")
    end
  end
end
