# schema.rb does not dump functions or triggers. Keep the rollup SQL in the
# dump so db:schema:load (tests, fresh databases) installs the same triggers
# the migration installs.
module ObservationRollupSchemaDumper
  def trailer(stream)
    if Rails.root.join("db/observation_rollups.sql").exist?
      stream.puts '  execute File.read(File.expand_path("observation_rollups.sql", __dir__))'
      stream.puts
    end
    super
  end
end

ActiveRecord::SchemaDumper.prepend(ObservationRollupSchemaDumper)
