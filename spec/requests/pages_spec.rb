require "rails_helper"

RSpec.describe "Pages", type: :request do
  %w[about privacy terms].each do |page|
    it "renders #{page}" do
      get "/#{page}"
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("public")
    end
  end

  it "404s unknown pages" do
    get "/pages/nope"
    expect(response).to have_http_status(:not_found)
  end
end
