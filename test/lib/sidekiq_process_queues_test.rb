require "test_helper"

class SidekiqProcessQueuesTest < ActiveSupport::TestCase
  PROCESS_QUEUES = {
    "config/sidekiq.yml" => %w[default],
    "config/sidekiq_sync.yml" => %w[sync],
    "config/sidekiq_iv_repair.yml" => %w[iv_repair],
    "config/sidekiq_iv_repair_scar.yml" => %w[iv_repair_scar],
    "config/sidekiq_historical.yml" => %w[backfill],
    "config/sidekiq_notifications.yml" => %w[notifications]
  }.freeze

  PROCFILE_CONFIGS = {
    "worker" => "config/sidekiq.yml",
    "sync_worker" => "config/sidekiq_sync.yml",
    "iv_repair_worker" => "config/sidekiq_iv_repair.yml",
    "iv_repair_scar_worker" => "config/sidekiq_iv_repair_scar.yml",
    "historical_worker" => "config/sidekiq_historical.yml",
    "notifications_worker" => "config/sidekiq_notifications.yml"
  }.freeze

  test "each Sidekiq process listens to exactly one dedicated queue" do
    assigned = PROCESS_QUEUES.values.flatten
    assert_equal assigned, assigned.uniq, "process configs must not share queues"

    PROCESS_QUEUES.each do |path, expected|
      config = load_sidekiq_yaml(path)
      assert_equal expected, Array(config[:queues]), "#{path} queues"
    end
  end

  test "Procfile maps each worker to its isolated Sidekiq config" do
    entries = File.readlines(Rails.root.join("Procfile"), chomp: true).to_h { |line|
      name, command = line.split(": ", 2)
      [ name, command ]
    }

    PROCFILE_CONFIGS.each do |process, path|
      command = entries.fetch(process)
      assert_includes command, "-C #{path}", "#{process} should start #{path}"
    end
  end

  test "scheduler routes IV scar catch-up onto the isolated scar queue" do
    schedule = load_sidekiq_yaml("config/sidekiq.yml").dig(:scheduler, :schedule)
    entry = schedule.fetch("iv_repair_scar_batch")

    assert_equal "IvRepairScarBatchJob", entry["class"]
    assert_equal "iv_repair_scar", entry["queue"]
    assert_equal "50 * * * 1-6", entry["cron"]
  end

  test "scheduler keeps tip IV repair on the tip queue" do
    schedule = load_sidekiq_yaml("config/sidekiq.yml").dig(:scheduler, :schedule)
    entry = schedule.fetch("iv_repair_batch")

    assert_equal "IvRepairBatchJob", entry["class"]
    assert_equal "iv_repair", entry["queue"]
    assert_equal "35 * * * 1-6", entry["cron"]
  end

  test "scar jobs declare the isolated iv_repair_scar queue" do
    assert_equal "iv_repair_scar", IvRepairScarJob.new.queue_name
    assert_equal "iv_repair_scar", IvRepairScarBatchJob.new.queue_name
    assert_equal "iv_repair", IvRepairJob.new.queue_name
    assert_equal "iv_repair", IvRepairBatchJob.new.queue_name
  end

  test "alert jobs and digest cron use the notifications queue" do
    assert_equal "notifications", AlertDeliveryJob.new.queue_name
    assert_equal "notifications", AlertEvaluationJob.new.queue_name
    assert_equal "notifications", AlertDigestSchedulerJob.new.queue_name
    assert_equal "notifications", AlertQuietScanJob.new.queue_name

    schedule = load_sidekiq_yaml("config/sidekiq.yml").dig(:scheduler, :schedule)
    assert_equal "notifications", schedule.fetch("alert_digest_scheduler")["queue"]
    assert_equal "notifications", schedule.fetch("alert_quiet_scan")["queue"]
  end

  test "AlertMailer deliver_later uses the notifications queue" do
    assert_equal :notifications, AlertMailer.deliver_later_queue_name
  end

  private

  def load_sidekiq_yaml(path)
    YAML.load_file(Rails.root.join(path))
  end
end
