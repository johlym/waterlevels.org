# frozen_string_literal: true

# SQLCommenter `release` value for PlanetScale Insights.
# Heroku runtime dyno metadata sets HEROKU_RELEASE_VERSION (for example v87).
# A blank value omits the tag.
module QueryReleaseTag
  module_function

  def value
    version = ENV["HEROKU_RELEASE_VERSION"].to_s.strip
    return if version.empty?

    "Release #{version}"
  end
end
