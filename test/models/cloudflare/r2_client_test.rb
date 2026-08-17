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

      client = enabled_client(fake)
      assert client.enabled?
      assert_nil client.get("missing")
      assert_equal :put, client.put("daily/v1/1/2024.json.gz", "gzipped")
      assert_equal "archive", fake.last[0]
      assert_equal "daily/v1/1/2024.json.gz", fake.last[1]
    end

    test "put retries InternalError then succeeds" do
      sleeps = []
      fake = FlakyS3.new(failures: 2, error: Aws::S3::Errors::InternalError.new(nil, "Please try again."))
      client = enabled_client(fake, sleeper: ->(seconds) { sleeps << seconds })

      assert_equal :put, client.put("daily/v1/26754/2026.json.gz", "gzipped")
      assert_equal 3, fake.calls
      assert_equal [ R2Client::BASE_BACKOFF, R2Client::BASE_BACKOFF * 2 ], sleeps
    end

    test "put gives up after repeated InternalError" do
      sleeps = []
      fake = FlakyS3.new(failures: 99, error: Aws::S3::Errors::InternalError.new(nil, "Please try again."))
      client = enabled_client(fake, sleeper: ->(seconds) { sleeps << seconds })

      error = assert_raises(R2Client::Error) { client.put("daily/v1/26754/2026.json.gz", "gzipped") }
      assert_match(/R2 put failed key=daily\/v1\/26754\/2026.json.gz/, error.message)
      assert_match(/Please try again/, error.message)
      assert_equal R2Client::MAX_ATTEMPTS, fake.calls
      assert_equal R2Client::MAX_ATTEMPTS - 1, sleeps.size
    end

    test "put does not retry AccessDenied" do
      sleeps = []
      fake = FlakyS3.new(failures: 99, error: Aws::S3::Errors::AccessDenied.new(nil, "denied"))
      client = enabled_client(fake, sleeper: ->(seconds) { sleeps << seconds })

      error = assert_raises(R2Client::Error) { client.put("daily/v1/1/2026.json.gz", "gzipped") }
      assert_match(/denied/, error.message)
      assert_equal 1, fake.calls
      assert_empty sleeps
    end

    test "get retries ServiceUnavailable then returns the object" do
      sleeps = []
      fake = FlakyS3.new(failures: 1, error: Aws::S3::Errors::ServiceUnavailable.new(nil, "unavailable"))
      client = enabled_client(fake, sleeper: ->(seconds) { sleeps << seconds })

      assert_equal "hello", client.get("daily/v1/1/2026.json.gz")
      assert_equal 2, fake.calls
      assert_equal [ R2Client::BASE_BACKOFF ], sleeps
    end

    test "get does not retry missing keys" do
      sleeps = []
      fake = FlakyS3.new(failures: 0)
      def fake.get_object(bucket:, key:)
        @calls = @calls.to_i + 1
        raise Aws::S3::Errors::NoSuchKey.new(nil, "missing")
      end
      client = enabled_client(fake, sleeper: ->(seconds) { sleeps << seconds })

      assert_nil client.get("missing")
      assert_equal 1, fake.calls
      assert_empty sleeps
    end

    private

    def enabled_client(fake, sleeper: ->(_seconds) { })
      R2Client.new(
        endpoint: "https://example.r2.cloudflarestorage.com",
        bucket: "archive",
        access_key_id: "id",
        secret_access_key: "secret",
        client: fake,
        sleeper: sleeper
      )
    end

    class FlakyS3
      attr_reader :calls

      def initialize(failures:, error: nil)
        @failures = failures
        @error = error
        @calls = 0
      end

      def get_object(bucket:, key:)
        fail_or_succeed!
        Struct.new(:body).new(StringIO.new("hello"))
      end

      def put_object(bucket:, key:, body:, content_type:)
        fail_or_succeed!
        true
      end

      private

      def fail_or_succeed!
        @calls += 1
        raise @error if @error && @calls <= @failures
      end
    end
  end
end
