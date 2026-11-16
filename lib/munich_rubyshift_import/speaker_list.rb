# frozen_string_literal: true

class MunichRubyshiftImport
  # data/speakers.yml, edited entry by entry, so that the entries the import doesn't change keep their exact text.
  class SpeakerList
    Entry = Struct.new(:text, :data)

    def initialize(path)
      @path = path
      @header, *chunks = File.read(path).split(/^(?=- )/)
      entries = Yerba.parse_file(path.to_s).to_a
      raise ArgumentError, "#{path} splits into #{chunks.size} entries, but has #{entries.size}" unless chunks.size == entries.size

      @entries = chunks.zip(entries).map { |text, data| Entry.new(text, data) }
    end

    # The entry becomes the person, so a value the person doesn't have is gone. Only the entry's aliases stay, which
    # the API doesn't have, and a renamed entry adds its old name to them, since other files may still refer to it.
    # Returns what happened, for the report.
    def merge(person)
      entry, found_by = find(person)
      return add(person) unless entry
      return "speakers.yml: left #{person["name"]} alone, GitHub #{entry.data["github"]} there and #{person["github"]} in the API" if found_by == "name" && other_github?(entry.data, person)

      merged = data_for(person).merge(entry.data.slice("aliases"))
      return if merged == entry.data

      old_name, old_slug = entry.data.values_at("name", "slug")
      renamed = merged["name"] != old_name

      if renamed
        aliases = Array(merged["aliases"]).reject { |other| [old_name, merged["name"]].include?(other["name"]) }
        alias_slug = (old_slug == merged["slug"]) ? old_name.parameterize : old_slug
        merged["aliases"] = [*aliases, {"name" => old_name, "slug" => alias_slug}]
      end

      entry.data = merged
      entry.text = YAMLWriter.dump([merged]).delete_prefix("---\n")
      renamed ? "speakers.yml: renamed #{old_name} to #{merged["name"]}" : "speakers.yml: updated #{merged["name"]}"
    end

    def write
      File.write(@path, @header + @entries.map(&:text).join)
    end

    private

    # The entry with the person's slug, GitHub handle, or name, in this order, and which of these found it.
    def find(person)
      %w[slug github name].each do |key|
        next if person[key].blank?

        entry = @entries.find { |candidate| values(candidate, key).any? { |value| value.to_s.casecmp?(person[key]) } }
        return [entry, key] if entry
      end

      nil
    end

    def values(entry, key)
      return [entry.data[key]] unless key == "name"

      [entry.data["name"], *Array(entry.data["aliases"]).map { |other| other["name"] }]
    end

    # The same name with another GitHub handle is most likely someone else.
    def other_github?(data, person)
      data["github"].present? && person["github"].present? && !data["github"].casecmp?(person["github"])
    end

    # Without a GitHub handle, the empty one that every speaker without one has.
    def data_for(person)
      {"name" => person["name"], "github" => ""}.merge(person.compact)
    end

    # In alphabetical order.
    def add(person)
      data = data_for(person)
      index = @entries.index { |other| other.data["name"].to_s.downcase > data["name"].to_s.downcase } || @entries.size
      @entries.insert(index, Entry.new(YAMLWriter.dump([data]).delete_prefix("---\n"), data))

      "speakers.yml: added #{data["name"]}"
    end
  end
end
