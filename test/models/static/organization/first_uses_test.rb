require "test_helper"

class Static::Organization::FirstUsesTest < ActiveSupport::TestCase
  include StaticDataSandbox

  setup do
    @base = Dir.mktmpdir("first_uses_base")
    @head = Dir.mktmpdir("first_uses_head")

    [@base, @head].each do |root|
      write_data_file(root, "data/alpha/series.yml", {"name" => "Alpha"})
      write_data_file(root, "data/beta/series.yml", {"name" => "Beta"})
      write_data_file(root, "data/alpha/alpha-2025/sponsors.yml", [{"tiers" => [{"name" => "Gold", "level" => 1, "sponsors" => [{"slug" => "appsignal"}]}]}])
      write_data_file(root, "data/beta/involvements.yml", [{"name" => "Organizer", "organizations" => ["typesense"]}])
    end

    organizations = [
      {"slug" => "appsignal", "name" => "AppSignal", "website" => "https://www.appsignal.com"},
      {"slug" => "typesense", "name" => "Typesense", "aliases" => [{"name" => "TypeSense", "slug" => "type-sense"}]}
    ]
    write_data_file(@base, "data/organizations.yml", organizations)
    # The head's name for appsignal comes from the pull request and isn't shown; the base's is what to compare against
    write_data_file(@head, "data/organizations.yml", [organizations.first.merge("name" => "@someone")] + organizations.drop(1) + [{"slug" => "planet-argon", "name" => "Planet Argon"}])
  end

  teardown do
    FileUtils.rm_rf(@base)
    FileUtils.rm_rf(@head)
  end

  test "lists existing organizations a series references for the first time, with the line" do
    path = write_data_file(@head, "data/beta/beta-2026/sponsors.yml", [{"tiers" => [{"name" => "Gold", "level" => 1, "sponsors" => [
      {"slug" => "type-sense"}, {"slug" => "planet-argon"}, {"slug" => "appsignal"}
    ]}, {"name" => "Silver", "level" => 2, "sponsors" => [{"slug" => "appsignal"}]}]}])
    write_data_file(@head, "data/alpha/involvements.yml", [{"name" => "Organizer", "organizations" => [{"slug" => "typesense", "from" => "2024"}]}])

    appsignal_lines = File.readlines(path).each_with_index.filter_map { |line, index| index + 1 if line.include?("appsignal") }
    changed_lines = {"data/beta/beta-2026/sponsors.yml" => Set[appsignal_lines.last]}

    findings = Static::Organization::FirstUses.new(base_root: @base, head_root: @head, changed_lines: changed_lines).findings

    assert_equal [["data/alpha/involvements.yml", "data/alpha", "typesense"], ["data/beta/beta-2026/sponsors.yml", "data/beta", "appsignal"]],
      findings.map { |finding| [finding.path, finding.series, finding.slug] }.sort

    # One finding per file, series and organization, on a line of the diff where there is one
    appsignal = findings.find { |finding| finding.slug == "appsignal" }
    assert_equal appsignal_lines.last, appsignal.line
    assert appsignal.in_diff
    assert_not findings.find { |finding| finding.slug == "typesense" }.in_diff
    assert_equal ["data/alpha"], appsignal.other_series
    assert_match "First time `data/beta` references the organization `appsignal`** (AppSignal, https://www.appsignal.com)", appsignal.body
    assert_match "It appears in data/alpha.", appsignal.body
  end

  test "only looks at the given files on the head side" do
    write_data_file(@head, "data/beta/beta-2026/sponsors.yml", [{"tiers" => [{"name" => "Gold", "level" => 1, "sponsors" => [{"slug" => "appsignal"}]}]}])

    first_uses = Static::Organization::FirstUses.new(base_root: @base, head_root: @head, paths: ["data/alpha/alpha-2025/sponsors.yml"])

    assert_empty first_uses.findings
  end

  test "finds nothing while the base has no organizations.yml" do
    FileUtils.rm(File.join(@base, "data/organizations.yml"))
    write_data_file(@head, "data/beta/beta-2026/sponsors.yml", [{"tiers" => [{"name" => "Gold", "level" => 1, "sponsors" => [{"slug" => "appsignal"}]}]}])

    assert_empty Static::Organization::FirstUses.new(base_root: @base, head_root: @head).findings
  end
end
