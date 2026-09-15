require "test_helper"

class RedisConfigTest < ActiveSupport::TestCase
  test "options verify Redis Cloud TLS certificates by default" do
    previous = ENV.delete("REDIS_SSL_VERIFY")
    begin
      opts = RedisConfig.options(default_url: "rediss://example.internal:6379")
      assert_equal OpenSSL::SSL::VERIFY_PEER, opts[:ssl_params][:verify_mode]
      assert_match %r{\Arediss://example\.internal:6379(?:/\d+)?\z}, opts[:url]
    ensure
      ENV["REDIS_SSL_VERIFY"] = previous if previous
    end
  end

  test "REDIS_SSL_VERIFY=none keeps VERIFY_NONE for self-signed hosts" do
    previous = ENV["REDIS_SSL_VERIFY"]
    ENV["REDIS_SSL_VERIFY"] = "none"
    begin
      opts = RedisConfig.options(default_url: "rediss://example.internal:6379")
      assert_equal OpenSSL::SSL::VERIFY_NONE, opts[:ssl_params][:verify_mode]
    ensure
      previous ? ENV["REDIS_SSL_VERIFY"] = previous : ENV.delete("REDIS_SSL_VERIFY")
    end
  end

  test "cache_options uses REDIS_CACHE_URL when set" do
    previous = ENV["REDIS_CACHE_URL"]
    ENV["REDIS_CACHE_URL"] = "rediss://cache.example:6379/0"
    begin
      opts = RedisConfig.cache_options
      assert_includes opts[:url], "cache.example"
    ensure
      previous ? ENV["REDIS_CACHE_URL"] = previous : ENV.delete("REDIS_CACHE_URL")
    end
  end

  test "defaults to local redis when REDIS_URL is unset" do
    with_parallel_worker_id(nil) do
      previous = ENV.delete("REDIS_URL")
      begin
        assert_equal RedisConfig::DEFAULT_URL, RedisConfig.url
      ensure
        ENV["REDIS_URL"] = previous if previous
      end
    end
  end

  test "isolates redis db per parallel test worker" do
    previous = ENV.delete("REDIS_URL")
    begin
      with_parallel_worker_id(3) do
        assert_equal "redis://127.0.0.1:6379/3", RedisConfig.url
      end

      with_parallel_worker_id(0) do
        assert_equal "redis://127.0.0.1:6379/0", RedisConfig.url
      end
    ensure
      previous ? ENV["REDIS_URL"] = previous : ENV.delete("REDIS_URL")
    end
  end

  private

  def with_parallel_worker_id(worker_id)
    previous_worker = ActiveSupport::TestCase.parallel_worker_id
    ActiveSupport::TestCase.parallel_worker_id = worker_id
    yield
  ensure
    ActiveSupport::TestCase.parallel_worker_id = previous_worker
    eigen = AdminDashboardStats.singleton_class
    eigen.remove_instance_variable(:@redis) if eigen.instance_variable_defined?(:@redis)
  end
end
