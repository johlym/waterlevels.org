require "test_helper"

module Cloudflare
  class R2ClientTest < ActiveSupport::TestCase
    test "disabled when credentials missing" do
      client = R2Client.new(endpoint: nil, bucket: nil, access_key_id: nil, secret_access_key: nil)
      assert_not client.enabled?
      assert_nil client.get("missing")
      assert_equal :skipped, client.put("k", "body")
    end

    test "get put use injected aws client" do
      fake = Object.new
      def fake.get_object(bucket:, key:)
        raise Aws::S3::Errors::NoSuchKey.new(nil, "missing") if key == "missing"

        body = StringIO.new("hello")
        Struct.new(:body).new(body)
      end

      def fake.put_object(bucket:, key:, body:, content_type:)
        @last = [ bucket, key, body, content_type ]
        true
      end

      def fake.last
        @last
      end

      client = R2Client.new(
        endpoint: "https://example.r2.cloudflarestorage.com",
        bucket: "archive",
        access_key_id: "id",
        secret_access_key: "secret",
        client: fake
      )
      assert client.enabled?
      assert_nil client.get("missing")
      assert_equal :put, client.put("daily/v1/1/2024.json.gz", "gzipped")
      assert_equal "archive", fake.last[0]
      assert_equal "daily/v1/1/2024.json.gz", fake.last[1]
    end
  end
end
