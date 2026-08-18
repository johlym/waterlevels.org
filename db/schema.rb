# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_18_220000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_counters", force: :cascade do |t|
    t.datetime "computed_at", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "source", default: "job", null: false
    t.datetime "updated_at", null: false
    t.bigint "value", default: 0, null: false
    t.index ["name"], name: "index_admin_counters_on_name", unique: true
  end

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["key"], name: "index_app_settings_on_key", unique: true
  end

  create_table "continuous_observations", force: :cascade do |t|
    t.string "approval_status"
    t.datetime "created_at", null: false
    t.datetime "observed_at", null: false
    t.string "qualifier"
    t.bigint "time_series_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 16, scale: 6, null: false
    t.index ["observed_at"], name: "index_continuous_observations_on_observed_at"
    t.index ["time_series_id", "observed_at"], name: "index_continuous_observations_on_ts_observed_at_incl_value", unique: true, include: ["value"]
  end

  create_table "daily_archive_shards", force: :cascade do |t|
    t.string "content_sha256", null: false
    t.datetime "created_at", null: false
    t.date "max_on"
    t.date "min_on"
    t.string "object_key", null: false
    t.integer "point_count", default: 0, null: false
    t.string "source_mix", default: "usgs", null: false
    t.datetime "synced_at", null: false
    t.bigint "time_series_id", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["max_on"], name: "index_daily_archive_shards_on_max_on"
    t.index ["min_on"], name: "index_daily_archive_shards_on_min_on"
    t.index ["object_key"], name: "index_daily_archive_shards_on_object_key", unique: true
    t.index ["time_series_id", "year"], name: "index_daily_archive_shards_on_time_series_id_and_year", unique: true
  end

  create_table "daily_observations", force: :cascade do |t|
    t.string "approval_status"
    t.datetime "created_at", null: false
    t.date "observed_on", null: false
    t.string "qualifier"
    t.bigint "time_series_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 16, scale: 6, null: false
    t.index ["observed_on"], name: "index_daily_observations_on_observed_on"
    t.index ["time_series_id", "observed_on"], name: "index_daily_observations_on_time_series_id_and_observed_on", unique: true
  end

  create_table "latest_observations", force: :cascade do |t|
    t.string "approval_status"
    t.datetime "created_at", null: false
    t.datetime "observed_at", null: false
    t.string "qualifier"
    t.datetime "source_last_modified_at"
    t.datetime "synced_at", null: false
    t.bigint "time_series_id", null: false
    t.string "unit_of_measure"
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 16, scale: 6, null: false
    t.index ["time_series_id"], name: "index_latest_observations_on_time_series_id", unique: true
  end

  create_table "monitoring_locations", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "agency_code", default: "USGS", null: false
    t.string "agency_name"
    t.string "county_code"
    t.string "county_name"
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.decimal "drainage_area", precision: 12, scale: 3
    t.string "flood_category"
    t.datetime "flood_category_observed_at"
    t.decimal "flood_stage_action", precision: 16, scale: 6
    t.decimal "flood_stage_major", precision: 16, scale: 6
    t.decimal "flood_stage_minor", precision: 16, scale: 6
    t.decimal "flood_stage_moderate", precision: 16, scale: 6
    t.boolean "has_discharge", default: false, null: false
    t.boolean "has_temperature", default: false, null: false
    t.boolean "has_water_level", default: false, null: false
    t.string "hydrologic_unit_code"
    t.string "latest_approval_status"
    t.string "latest_discharge_unit"
    t.decimal "latest_discharge_value", precision: 16, scale: 6
    t.datetime "latest_observed_at"
    t.decimal "latest_temperature_c", precision: 8, scale: 3
    t.string "latest_water_level_parameter_code"
    t.string "latest_water_level_unit"
    t.decimal "latest_water_level_value", precision: 16, scale: 6
    t.decimal "latitude", precision: 10, scale: 7, null: false
    t.decimal "longitude", precision: 10, scale: 7, null: false
    t.datetime "metadata_synced_at"
    t.string "name", null: false
    t.jsonb "nearby_station_ids", default: [], null: false
    t.string "nwps_lid"
    t.boolean "nwps_matched", default: false, null: false
    t.datetime "nwps_synced_at"
    t.string "search_name", null: false
    t.string "site_number", null: false
    t.string "site_type_code"
    t.string "site_type_name"
    t.string "slug", null: false
    t.string "state_code", null: false
    t.string "state_name"
    t.string "time_zone"
    t.datetime "updated_at", null: false
    t.string "usgs_monitoring_location_id", null: false
    t.index ["active", "latest_observed_at"], name: "index_monitoring_locations_on_active_and_latest_observed_at"
    t.index ["flood_category"], name: "index_monitoring_locations_on_flood_category"
    t.index ["has_discharge"], name: "index_monitoring_locations_on_has_discharge", where: "(has_discharge = true)"
    t.index ["has_water_level"], name: "index_monitoring_locations_on_has_water_level", where: "(has_water_level = true)"
    t.index ["latitude", "longitude"], name: "index_monitoring_locations_on_latitude_and_longitude"
    t.index ["nwps_lid"], name: "index_monitoring_locations_on_nwps_lid", where: "(nwps_lid IS NOT NULL)"
    t.index ["nwps_matched"], name: "index_monitoring_locations_on_nwps_matched", where: "(nwps_matched = true)"
    t.index ["search_name"], name: "index_monitoring_locations_on_search_name"
    t.index ["site_number"], name: "index_monitoring_locations_on_site_number", unique: true
    t.index ["state_code", "county_name", "name"], name: "idx_on_state_code_county_name_name_ac7d4d7687"
    t.index ["usgs_monitoring_location_id"], name: "index_monitoring_locations_on_usgs_monitoring_location_id", unique: true
  end

  create_table "peak_observations", force: :cascade do |t|
    t.string "approval_status"
    t.datetime "created_at", null: false
    t.datetime "observed_at"
    t.string "peak_kind", default: "high", null: false
    t.bigint "time_series_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 16, scale: 6, null: false
    t.integer "water_year", null: false
    t.index ["time_series_id", "water_year", "peak_kind"], name: "index_peak_observations_unique", unique: true
  end

  create_table "time_series", force: :cascade do |t|
    t.datetime "begins_at"
    t.integer "continuous_max_gap_seconds"
    t.datetime "continuous_newest_at"
    t.datetime "continuous_prev_at"
    t.datetime "created_at", null: false
    t.datetime "ends_at"
    t.boolean "has_continuous_anchor", default: false, null: false
    t.datetime "iv_scar_checked_at"
    t.integer "iv_scar_checked_max_gap_seconds"
    t.string "measurement_kind", null: false
    t.datetime "metadata_synced_at"
    t.bigint "monitoring_location_id", null: false
    t.string "parameter_code", null: false
    t.string "parameter_description"
    t.string "parameter_name"
    t.boolean "primary_series", default: false, null: false
    t.boolean "selected_for_display", default: false, null: false
    t.string "statistic_code"
    t.string "statistic_name"
    t.string "unit_of_measure"
    t.datetime "updated_at", null: false
    t.boolean "usgs_daily_absent", default: false, null: false
    t.string "usgs_time_series_id", null: false
    t.index ["continuous_max_gap_seconds"], name: "index_time_series_selected_anchored_on_max_gap", where: "((selected_for_display = true) AND (has_continuous_anchor = true))"
    t.index ["monitoring_location_id", "measurement_kind", "selected_for_display"], name: "index_time_series_on_location_kind_selected"
    t.index ["monitoring_location_id"], name: "index_time_series_selected_on_location", where: "(selected_for_display = true)"
    t.index ["usgs_time_series_id"], name: "index_time_series_on_usgs_time_series_id", unique: true
  end

  add_foreign_key "continuous_observations", "time_series"
  add_foreign_key "daily_archive_shards", "time_series"
  add_foreign_key "daily_observations", "time_series"
  add_foreign_key "latest_observations", "time_series"
  add_foreign_key "peak_observations", "time_series"
  add_foreign_key "time_series", "monitoring_locations"
end
