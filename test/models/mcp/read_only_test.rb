require "test_helper"

class Mcp::ReadOnlyTest < ActiveSupport::TestCase
  test "writes inside the read-only transaction raise ActiveRecord::ReadOnlyError" do
    location = create(:monitoring_location)
    original = location.name

    assert_raises(ActiveRecord::ReadOnlyError) do
      Mcp::ReadOnly.during { location.update!(name: "Must Not Persist") }
    end

    assert_equal original, location.reload.name
  end
end
