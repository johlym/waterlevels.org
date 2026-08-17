require "aws-sdk-s3"

module Cloudflare
  # S3-compatible client for the private yearly-archive bucket.
  # No-ops when CLOUDFLARE_R2_* credentials are unset (local/dev/test).
  class R2Client
    Error = Class.new(StandardError)

    MAX_ATTEMPTS = 4
    BASE_BACKOFF = 1.0

    # Cloudflare R2 maps these S3 codes to transient 5xx/429 responses and
    # documents "retry the request" / exponential backoff as the fix.
    TRANSIENT_ERROR_CLASSES = [
      Aws::S3::Errors::InternalError,
      Aws::S3::Errors::ServiceUnavailable,
      Aws::S3::Errors::SlowDown,
      Aws::S3::Errors::RequestTimeout
    ].freeze

    TRANSIENT_ERROR_CODES = %w[
      InternalError
      ServiceUnavailable
      SlowDown
      RequestTimeout
      TooManyRequests
    ].freeze

    def initialize(
      endpoint: ENV["CLOUDFLARE_R2_URL"],
      bucket: ENV["CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET"],
      access_key_id: ENV["CLOUDFLARE_R2_ACCESS_KEY_ID"],
      secret_access_key: ENV["CLOUDFLARE_R2_SECRET_ACCESS_KEY"],
      client: nil,
      sleeper: nil
    )
      @endpoint = endpoint.to_s.presence
      @bucket = bucket.to_s.presence
      @access_key_id = access_key_id.to_s.presence
      @secret_access_key = secret_access_key.to_s.presence
      @client = client
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def enabled?
      @endpoint.present? && @bucket.present? && @access_key_id.present? && @secret_access_key.present?
    end

    def get(key)
      return unless enabled?

      with_retries("get", key) do
        response = s3_client.get_object(bucket: @bucket, key: key)
        response.body.read.to_s.force_encoding(Encoding::BINARY)
      end
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      nil
    end

    def put(key, body, content_type: "application/gzip")
      return :skipped unless enabled?

      with_retries("put", key) do
        s3_client.put_object(
          bucket: @bucket,
          key: key,
          body: body,
          content_type: content_type
        )
        :put
      end
    end

    def head(key)
      return unless enabled?

      with_retries("head", key) do
        s3_client.head_object(bucket: @bucket, key: key)
      end
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end

    private

    def with_retries(operation, key)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
        raise
      rescue Aws::S3::Errors::ServiceError => e
        if transient_error?(e) && attempts < MAX_ATTEMPTS
          Rails.logger.warn(
            "R2 #{operation} retry #{attempts}/#{MAX_ATTEMPTS} key=#{key}: #{e.message}"
          )
          @sleeper.call(BASE_BACKOFF * attempts)
          retry
        end
        raise Error, "R2 #{operation} failed key=#{key}: #{e.message}"
      end
    end

    def transient_error?(error)
      return true if TRANSIENT_ERROR_CLASSES.any? { |klass| error.is_a?(klass) }

      TRANSIENT_ERROR_CODES.include?(error.code.to_s)
    end

    def s3_client
      @client ||= Aws::S3::Client.new(
        endpoint: @endpoint,
        access_key_id: @access_key_id,
        secret_access_key: @secret_access_key,
        region: "auto",
        force_path_style: true
      )
    end
  end
end
