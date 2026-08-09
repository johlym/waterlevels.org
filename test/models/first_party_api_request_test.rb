require "test_helper"

class FirstPartyApiRequestTest < ActiveSupport::TestCase
  test "allows same-origin browser requests with the client header" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["X-WaterLevels-Client"] = "web"
    request.headers["Sec-Fetch-Site"] = "same-origin"

    assert FirstPartyApiRequest.allowed?(request)
  end

  test "allows matching Origin when Sec-Fetch-Site is absent" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["X-WaterLevels-Client"] = "web"
    request.headers["Origin"] = "https://www.example.com"

    assert FirstPartyApiRequest.allowed?(request)
  end

  test "allows matching Referer when Sec-Fetch-Site is absent" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["X-WaterLevels-Client"] = "web"
    request.headers["Referer"] = "https://www.example.com/map"

    assert FirstPartyApiRequest.allowed?(request)
  end

  test "allows APP_HOST when request host differs" do
    previous = ENV["APP_HOST"]
    ENV["APP_HOST"] = "waterlevels.org"

    request = ActionDispatch::TestRequest.create
    request.host = "heroku-app.example"
    request.headers["X-WaterLevels-Client"] = "web"
    request.headers["Origin"] = "https://waterlevels.org"

    assert FirstPartyApiRequest.allowed?(request)
  ensure
    if previous
      ENV["APP_HOST"] = previous
    else
      ENV.delete("APP_HOST")
    end
  end

  test "rejects missing client header" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["Sec-Fetch-Site"] = "same-origin"

    assert_not FirstPartyApiRequest.allowed?(request)
  end

  test "rejects cross-site fetch context" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["X-WaterLevels-Client"] = "web"
    request.headers["Sec-Fetch-Site"] = "cross-site"

    assert_not FirstPartyApiRequest.allowed?(request)
  end

  test "rejects bare requests with no first-party context" do
    request = ActionDispatch::TestRequest.create
    request.host = "www.example.com"
    request.headers["X-WaterLevels-Client"] = "web"

    assert_not FirstPartyApiRequest.allowed?(request)
  end
end
