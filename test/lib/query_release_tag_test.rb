require "test_helper"

class QueryReleaseTagTest < ActiveSupport::TestCase
  test "value is Release plus the heroku release version" do
    with_heroku_release("v87") do
      assert_equal "Release v87", QueryReleaseTag.value
    end
  end

  test "value is nil when heroku metadata is blank" do
    with_heroku_release(nil) do
      assert_nil QueryReleaseTag.value
    end

    with_heroku_release("   ") do
      assert_nil QueryReleaseTag.value
    end
  end

  test "application config uses sqlcommenter and the release tag" do
    assert_equal :sqlcommenter, Rails.application.config.active_record.query_log_tags_format

    with_heroku_release("v87") do
      assert_equal "Release v87", release_tag_proc.call
    end

    with_heroku_release(nil) do
      assert_nil release_tag_proc.call
    end
  end

  test "production enables sqlcommenter query tags" do
    source = Rails.root.join("config/environments/production.rb").read

    assert_match(/config\.active_record\.query_log_tags_enabled = true/, source)
    assert_match(/config\.active_record\.query_log_tags_format = :sqlcommenter/, source)
  end

  test "queries sent to postgres carry the sqlcommenter release tag" do
    with_heroku_release("v87") do
      with_query_log_tags do
        sql = probe_sql
        assert_equal 1, probe_result
        assert_includes sql, "/*application='Waterlevels',release='Release%20v87'*/"
      end
    end
  end

  test "queries omit the release tag when heroku metadata is blank" do
    with_heroku_release(nil) do
      with_query_log_tags do
        sql = probe_sql
        assert_includes sql, "/*application='Waterlevels'*/"
        refute_includes sql, "release="
      end
    end
  end

  private

  def release_tag_proc
    tags = Rails.application.config.active_record.query_log_tags
    tags.grep(Hash).reduce({}, :merge).fetch(:release)
  end

  def probe_sql
    @probe_sql
  end

  def probe_result
    @probe_result
  end

  def with_query_log_tags
    logs = ActiveRecord::QueryLogs
    previous = {
      tags: logs.tags,
      formatter: logs.tags_formatter,
      taggings: logs.taggings,
      transformers: ActiveRecord.query_transformers.dup
    }
    logs.taggings = logs.taggings.merge(
      application: Rails.application.class.name.split("::").first
    )
    logs.tags = Rails.application.config.active_record.query_log_tags.dup
    logs.tags_formatter = Rails.application.config.active_record.query_log_tags_format
    logs.clear_cache
    ActiveRecord.query_transformers |= [ logs ]

    sqls = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql] if payload[:sql]
    end
    @probe_result = nil
    @probe_sql = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      ActiveRecord::Base.connection.uncached do
        @probe_result = ActiveRecord::Base.connection.select_value(
          "SELECT 1 AS query_release_tag_probe"
        )
      end
    end
    @probe_sql = sqls.find { |statement| statement.include?("query_release_tag_probe") }
    assert @probe_sql, "expected the probe query to be logged"
    yield
  ensure
    logs.taggings = previous[:taggings]
    logs.tags = previous[:tags]
    logs.tags_formatter = previous[:formatter]
    logs.clear_cache
    ActiveRecord.query_transformers = previous[:transformers]
  end

  def with_heroku_release(version)
    previous = ENV["HEROKU_RELEASE_VERSION"]
    if version.nil?
      ENV.delete("HEROKU_RELEASE_VERSION")
    else
      ENV["HEROKU_RELEASE_VERSION"] = version
    end
    yield
  ensure
    if previous.nil?
      ENV.delete("HEROKU_RELEASE_VERSION")
    else
      ENV["HEROKU_RELEASE_VERSION"] = previous
    end
  end
end
