module DailyArchive
  # Filesystem stand-in for Cloudflare R2 — local/dev iteration without credentials.
  # Object keys map to files under +root+ (default tmp/daily_archive).
  class DiskStore
    def initialize(root: nil)
      relative = root.presence || ENV["DAILY_ARCHIVE_LOCAL_PATH"].presence || "tmp/daily_archive"
      @root = Pathname.new(relative)
      @root = Rails.root.join(@root) unless @root.absolute?
    end

    def enabled?
      true
    end

    def root
      @root
    end

    def get(key)
      path = path_for(key)
      return unless path.file?

      path.binread
    end

    def put(key, body, content_type: "application/gzip")
      path = path_for(key)
      path.dirname.mkpath
      path.binwrite(body.to_s.b)
      :put
    end

    def head(key)
      path_for(key).file? || nil
    end

    private

    def path_for(key)
      clean = key.to_s.delete_prefix("/")
      raise ArgumentError, "blank archive key" if clean.blank?

      path = @root.join(clean).expand_path
      unless path.to_s.start_with?(@root.expand_path.to_s + File::SEPARATOR) || path == @root.expand_path
        raise ArgumentError, "archive key escapes root: #{key}"
      end

      path
    end
  end
end
