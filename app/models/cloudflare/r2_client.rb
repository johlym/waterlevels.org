require "aws-sdk-s3"

module Cloudflare
  # S3-compatible client for the private yearly-archive bucket.
  # No-ops when CLOUDFLARE_R2_* credentials are unset (local/dev/test).
  class R2Client
    Error = Class.new(StandardError)

    def initialize(
      endpoint: ENV["CLOUDFLARE_R2_URL"],
      bucket: ENV["CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET"],
      access_key_id: ENV["CLOUDFLARE_R2_ACCESS_KEY_ID"],
      secret_access_key: ENV["CLOUDFLARE_R2_SECRET_ACCESS_KEY"],
      client: nil
    )
      @endpoint = endpoint.to_s.presence
      @bucket = bucket.to_s.presence
      @access_key_id = access_key_id.to_s.presence
      @secret_access_key = secret_access_key.to_s.presence
      @client = client
    end

    def enabled?
      @endpoint.present? && @bucket.present? && @access_key_id.present? && @secret_access_key.present?
    end

    def get(key)
      return unless enabled?

      response = s3_client.get_object(bucket: @bucket, key: key)
      response.body.read.to_s.force_encoding(Encoding::BINARY)
    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      nil
    rescue Aws::S3::Errors::ServiceError => e
      raise Error, "R2 get failed key=#{key}: #{e.message}"
    end

    def put(key, body, content_type: "application/gzip")
      return :skipped unless enabled?

      s3_client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        content_type: content_type
      )
      :put
    rescue Aws::S3::Errors::ServiceError => e
      raise Error, "R2 put failed key=#{key}: #{e.message}"
    end

    def head(key)
      return unless enabled?

      s3_client.head_object(bucket: @bucket, key: key)
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    rescue Aws::S3::Errors::ServiceError => e
      raise Error, "R2 head failed key=#{key}: #{e.message}"
    end

    private

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
