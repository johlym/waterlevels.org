require "test_helper"

class RedisConfigTest < ActiveSupport::TestCase
  test "options include self-signed cert verify mode" do
    opts = RedisConfig.options(default_url: "rediss://example.internal:6379")
    assert_equal OpenSSL::SSL::VERIFY_NONE, opts[:ssl_params][:verify_mode]
    assert_match %r{\Arediss://example\.internal:6379(?:/\d+)?\z}, opts[:url]
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
