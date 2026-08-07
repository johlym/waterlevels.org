require "test_helper"

module DailyArchive
  class CodecTest < ActiveSupport::TestCase
    test "encode and decode round-trip" do
      points = [
        { "d" => "2024-01-02", "v" => 2.5, "s" => "usgs", "a" => "Approved" },
        { "d" => "2024-01-01", "v" => 1.25, "s" => "derived" }
      ]
      body = Codec.encode(points)
      decoded = Codec.decode(body)

      assert_equal "2024-01-01", decoded.first["d"]
      assert_equal 1.25, decoded.first["v"]
      assert_equal "derived", decoded.first["s"]
      assert_equal "Approved", decoded.last["a"]
    end

    test "merge prefers usgs over derived" do
      existing = [ { "d" => "2024-01-01", "v" => 1.0, "s" => "derived" } ]
      incoming = [ { "d" => "2024-01-01", "v" => 2.0, "s" => "usgs" } ]
      merged = Codec.merge(existing, incoming)

      assert_equal 1, merged.size
      assert_equal 2.0, merged.first["v"]
      assert_equal "usgs", merged.first["s"]
    end

    test "merge does not let derived overwrite usgs" do
      existing = [ { "d" => "2024-01-01", "v" => 2.0, "s" => "usgs" } ]
      incoming = [ { "d" => "2024-01-01", "v" => 9.0, "s" => "derived" } ]
      merged = Codec.merge(existing, incoming)

      assert_equal 2.0, merged.first["v"]
      assert_equal "usgs", merged.first["s"]
    end
  end
end
