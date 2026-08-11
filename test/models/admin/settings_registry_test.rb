require "test_helper"

class Admin::SettingsRegistryTest < ActiveSupport::TestCase
  test "registers expected groups with descriptions" do
    keys = Admin::SettingsRegistry.groups.map(&:key)
    assert_includes keys, :pipeline_jobs
    assert_includes keys, :ingestion_throughput
    assert_includes keys, :daily_archive
    assert_includes keys, :history_retention
    assert_includes keys, :maintenance

    Admin::SettingsRegistry.groups.each do |group|
      assert group.title.present?
      assert group.description.present?
    end
  end

  test "every setting has label and description" do
    Admin::SettingsRegistry.settings.each do |setting|
      assert setting.label.present?, "#{setting.key} missing label"
      assert setting.description.present?, "#{setting.key} missing description"
    end
  end

  test "every maintenance action has label description and callable" do
    actions = Admin::SettingsRegistry.actions
    assert actions.any?
    actions.each do |action|
      assert action.label.present?, "#{action.key} missing label"
      assert action.description.present?, "#{action.key} missing description"
      assert action.confirm.present?, "#{action.key} missing confirm"
      assert_respond_to action, :call
    end
  end
end
