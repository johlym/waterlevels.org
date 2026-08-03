require "test_helper"

class GlossaryTermsTest < ActiveSupport::TestCase
  test "prefers full datum names over short abbreviations" do
    assert_match GlossaryTerms::PATTERN, "Elevation (NAVD 1988)"
    match = GlossaryTerms::PATTERN.match("Elevation (NAVD 1988)")
    assert_equal "NAVD 1988", match[0]

    match = GlossaryTerms::PATTERN.match("Elevation (NGVD 1929)")
    assert_equal "NGVD 1929", match[0]
  end

  test "defines expected glossary terms" do
    %w[datum NGVD NAVD Provisional].each do |term|
      assert GlossaryTerms.definition_for(term).present? ||
        GlossaryTerms::ENTRIES.any? { |entry| entry[:term].include?(term) }
    end

    assert_includes GlossaryTerms.definition_for("datum"), "reference surface"
    assert_includes GlossaryTerms.definition_for("Provisional"), "revised"
  end
end
