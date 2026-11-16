require "test_helper"

class MunichRubyshiftImport::YAMLWriterTest < ActiveSupport::TestCase
  test "lays values out like yerba apply" do
    value = {
      "id" => "meetup-2026-01-22",
      "hybrid" => true,
      "level" => 1,
      "description" => "Dear Rubyists,\n\n  indented\nbye",
      "coordinates" => {"latitude" => 48.1, "longitude" => 11.5},
      "speakers" => ["Anna", "Ben"],
      "talks" => [{"id" => "a", "description" => "two\nlines", "tags" => []}],
      "nothing" => nil
    }

    assert_equal <<~YAML, MunichRubyshiftImport::YAMLWriter.dump(value)
      ---
      id: "meetup-2026-01-22"
      hybrid: true
      level: 1
      description: |-
        Dear Rubyists,

          indented
        bye
      coordinates:
        latitude: 48.1
        longitude: 11.5
      speakers:
        - "Anna"
        - "Ben"
      talks:
        - id: "a"
          description: |-
            two
            lines
          tags: []
      nothing: null
    YAML
  end

  test "writes text a literal block would change double-quoted" do
    ["ends with a newline\n", " starts with a space\nsecond line", "a\r\nwindows line", "a bell \a\nhere", "\"quotes\": and # signs"].each do |text|
      yaml = MunichRubyshiftImport::YAMLWriter.dump({"text" => text, "list" => [text]})

      assert_equal({"text" => text, "list" => [text]}, Yerba.parse(yaml).to_h)
    end
  end
end
