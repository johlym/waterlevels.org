require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  %w[about disclosures faq privacy terms].each do |page|
    test "renders #{page}" do
      get "/#{page}"
      assert_response :success
      assert_includes response.headers["Cache-Control"], "public"
    end
  end

  test "404s unknown pages" do
    get "/pages/nope"
    assert_response :not_found
  end
end
