# Cursor for StationCatalogSync so a killed Sunday national run (or a retried
# state bootstrap) skips parameter codes that already finished instead of
# re-paging latest-continuous from the start.
#
# Grain is a finished parameter_code. USGS pages by `next` link, so mid-parameter
# resume is out of scope — the in-flight code is re-done.
#
# Kept USGS location ids must be persisted: prune_inactive_locations! uses that
# set as the allow-list, and skipping a completed code would otherwise delete
# stations only seen in that collection.
class StationCatalogCheckpoint
  CACHE_KEY_PREFIX = "catalog:sync_checkpoint".freeze
  TTL = 7.days

  class << self
    def resume_or_start!(state: nil, as_of: Time.current, parameter_codes: Usgs::ParameterCodes::ALL)
      scope = scope_token(state)
      fingerprint = fingerprint_for(state: state, as_of: as_of, parameter_codes: parameter_codes)
      raw = read_raw(state: state)
      if raw && raw["fingerprint"] == fingerprint
        return new(raw, state: scope, resumed: true)
      end

      clear!(state)
      start!(state: scope, fingerprint: fingerprint)
    end

    def start!(state:, fingerprint:)
      scope = scope_token(state)
      checkpoint = new(
        {
          "fingerprint" => fingerprint,
          "completed_parameter_codes" => [],
          "kept_location_ids" => [],
          "discovered_rows" => 0,
          "started_at" => Time.current.utc.iso8601
        },
        state: scope,
        resumed: false
      )
      checkpoint.save!
      checkpoint
    end

    def clear!(state = nil)
      Rails.cache.delete(cache_key_for(state))
    end

    def clear_all!
      scope_tokens.each { |token| Rails.cache.delete(cache_key_for(token)) }
    end

    def read_raw(state: nil)
      raw = Rails.cache.read(cache_key_for(state))
      raw.is_a?(Hash) ? raw.stringify_keys : nil
    end

    def fingerprint_for(state:, as_of:, parameter_codes: Usgs::ParameterCodes::ALL)
      codes = Array(parameter_codes).map(&:to_s).join(",")
      "scope=#{scope_token(state)};week=#{week_id(as_of)};codes=#{codes}"
    end

    def week_id(as_of)
      as_of.utc.to_date.beginning_of_week(:sunday).iso8601
    end

    def cache_key_for(state)
      "#{CACHE_KEY_PREFIX}:#{scope_token(state)}"
    end

    def scope_token(state)
      postal = state && Usgs::StateCodes.try_normalize_postal(state)
      postal.presence || "national"
    end

    def scope_tokens
      [ "national" ] + Usgs::StateCodes::STATES.keys
    end
  end

  attr_reader :resumed

  def initialize(data, state:, resumed: false)
    @data = data.stringify_keys
    @state = self.class.scope_token(state)
    @resumed = resumed
  end

  def fingerprint
    @data["fingerprint"].to_s
  end

  def completed_parameter_codes
    Array(@data["completed_parameter_codes"]).map(&:to_s)
  end

  def remaining_parameter_codes
    Usgs::ParameterCodes::ALL.map(&:to_s) - completed_parameter_codes
  end

  def completed?(parameter_code)
    completed_parameter_codes.include?(parameter_code.to_s)
  end

  def kept_location_ids
    Array(@data["kept_location_ids"]).map(&:to_s)
  end

  def discovered_rows
    @data["discovered_rows"].to_i
  end

  def mark_parameter!(parameter_code, kept_location_ids:, discovered_rows: 0)
    code = parameter_code.to_s
    codes = completed_parameter_codes
    codes << code unless codes.include?(code)
    @data["completed_parameter_codes"] = codes
    @data["kept_location_ids"] = (self.kept_location_ids + Array(kept_location_ids).map(&:to_s)).uniq
    @data["discovered_rows"] = self.discovered_rows + discovered_rows.to_i
    save!
  end

  def clear!
    self.class.clear!(@state)
  end

  def save!
    Rails.cache.write(self.class.cache_key_for(@state), @data, expires_in: TTL)
    self
  end
end
