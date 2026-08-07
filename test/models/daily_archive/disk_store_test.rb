require "test_helper"
require "fileutils"

module DailyArchive
  class DiskStoreTest < ActiveSupport::TestCase
    setup do
      @root = Rails.root.join("tmp/daily_archive_test_#{Process.pid}")
      FileUtils.rm_rf(@root)
      @store = DiskStore.new(root: @root)
      DailyArchive.store = @store
      ENV["DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST"] = "1"
      ENV["DAILY_ARCHIVE_STORE"] = "local"
    end

    teardown do
      DailyArchive.reset_store!
      FileUtils.rm_rf(@root)
      ENV.delete("DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST")
      ENV.delete("DAILY_ARCHIVE_STORE")
      ENV.delete("DAILY_ARCHIVE_HOT_RETENTION_DAYS")
    end

    test "put and get round-trip on disk" do
      key = DailyArchive.object_key(42, 2024)
      body = Codec.encode([ { "d" => "2024-05-01", "v" => 1.5, "s" => "usgs" } ])
      assert_equal :put, @store.put(key, body)
      assert_equal body, @store.get(key)
      assert @store.head(key)
    end

    test "build_store selects disk when DAILY_ARCHIVE_STORE=local" do
      DailyArchive.reset_store!
      store = DailyArchive.build_store
      assert_instance_of DiskStore, store
      assert store.enabled?
    end

    test "build_store ignores local store in test without allow flag" do
      ENV.delete("DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST")
      DailyArchive.reset_store!
      assert_instance_of Cloudflare::R2Client, DailyArchive.build_store
    end

    test "hot_cutoff_on honors DAILY_ARCHIVE_HOT_RETENTION_DAYS" do
      ENV["DAILY_ARCHIVE_HOT_RETENTION_DAYS"] = "7"
      assert_equal 7.days.ago.to_date, DailyArchive.hot_cutoff_on
    end
  end
end
