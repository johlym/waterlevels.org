module DailyArchive
  # In-process S3 stand-in for tests.
  class MemoryStore
    def initialize
      @objects = {}
    end

    def enabled?
      true
    end

    def get(key)
      @objects[key]
    end

    def put(key, body, content_type: "application/gzip")
      @objects[key] = body.to_s.b
      :put
    end

    def head(key)
      get(key) ? true : nil
    end

    def clear!
      @objects.clear
    end

    def keys
      @objects.keys
    end
  end
end
