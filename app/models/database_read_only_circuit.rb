# When Postgres is briefly read-only (plan upgrades, failover), trip this circuit so
# already-queued sync/backfill jobs stop calling external APIs and retrying into a
# Sidekiq backlog that outlives the maintenance window.
class DatabaseReadOnlyCircuit
  KEY = "database:read_only_circuit"
  DEFAULT_TTL = 5.minutes

  def self.open!(ttl: DEFAULT_TTL)
    Rails.cache.write(KEY, true, expires_in: ttl)
  end

  def self.open?
    Rails.cache.exist?(KEY)
  end

  def self.clear!
    Rails.cache.delete(KEY)
  end

  def self.read_only_error?(error)
    current = error
    while current
      return true if defined?(PG::ReadOnlySqlTransaction) && current.is_a?(PG::ReadOnlySqlTransaction)
      return true if current.message.match?(/read[- ]only transaction|cannot execute \w+ in a read-only/i)

      current = current.cause
    end
    false
  end
end
