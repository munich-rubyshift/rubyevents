# frozen_string_literal: true

require "open3"

module Static
  class Organization
    # Lines where a series references an existing organization for the first time: a sponsors.yml or involvements.yml
    # in the series' folder names an organization that was already in data/organizations.yml before, but no file of
    # that series named it. Giving a different organization an existing slug merges the two by accident, so a human
    # checks each first use. Organizations the change adds are new, not reused, and aren't listed.
    class FirstUses
      Reference = Data.define(:series, :slug, :path, :line)

      FILES = %w[sponsors.yml involvements.yml].freeze

      # name, website and other_series come from the base, which is what the reviewer compares against
      Finding = Data.define(:series, :slug, :path, :line, :in_diff, :name, :website, :other_series) do
        def key
          "#{series} #{slug}"
        end

        def summary
          "`#{series}` uses `#{slug}` (#{name}) for the first time"
        end

        def body
          used = if other_series.empty?
            "No other series references it yet."
          else
            listed = other_series.first(5).join(", ")
            "It appears in #{listed}#{" and #{other_series.size - 5} more series" if other_series.size > 5}."
          end

          <<~MARKDOWN.strip
            **First time `#{series}` references the organization `#{slug}`** (#{[name, website].compact.join(", ")}).

            #{used} Please check this is the same organization and not a different one that happens to share its slug or name. A different organization needs its own entry in `data/organizations.yml`.
          MARKDOWN
        end
      end

      # The data/ folder of two git refs, compared on the sponsors.yml and involvements.yml files that differ.
      # Without `head`, the working tree is compared, uncommitted changes included.
      def self.between(base:, head: nil)
        Dir.mktmpdir("first_uses") do |dir|
          base_commit = git("merge-base", base, head || "HEAD").strip
          base_root = export(base_commit, File.join(dir, "base"))
          head_root = head ? export(head, File.join(dir, "head")) : Rails.root.to_s

          paths = git("diff", "--name-only", "-z", "--diff-filter=d", base_commit, *head, "--", "data").split("\0")
          paths += git("ls-files", "--others", "--exclude-standard", "-z", "--", "data").split("\0") unless head
          paths = paths.select { |path| File.basename(path).in?(FILES) }

          # An export-ignore in a .gitattributes would leave a file out of the export, and so out of the check
          hidden = paths.reject { |path| File.exist?(File.join(head_root, path)) }
          raise "#{hidden.join(", ")} missing from the export of #{head}" if hidden.any?

          yield new(base_root: base_root, head_root: head_root, paths: paths, changed_lines: (changed_lines(base_commit, head) if head))
        end
      end

      def self.git(*arguments)
        output, status = Open3.capture2("git", "-c", "core.quotePath=false", *arguments, chdir: Rails.root.to_s)
        raise "git #{arguments.join(" ")} failed" unless status.success?

        output
      end

      # path => the head's line numbers the diff shows, which are the lines GitHub takes review comments on. With
      # rename detection, like GitHub: a file that only moved has none.
      def self.changed_lines(base_commit, head)
        lines = Hash.new { |hash, path| hash[path] = Set.new }
        path = nil

        git("diff", "-U0", "-M", base_commit, head, "--", "data").each_line do |line|
          if line.start_with?("+++ ")
            path = line.chomp.delete_prefix("+++ b/")
          elsif (hunk = line.match(/\A@@ -\S+ \+(\d+)(?:,(\d+))? @@/))
            start = hunk[1].to_i
            lines[path].merge(start...(start + (hunk[2] || 1).to_i))
          end
        end

        lines
      end

      def self.export(ref, root)
        FileUtils.mkdir_p(root)
        statuses = Open3.pipeline(["git", "archive", "--format=tar", ref, "data"], ["tar", "-x", "-C", root], chdir: Rails.root.to_s)
        raise "Could not export data/ of #{ref}" unless statuses.all?(&:success?)

        root
      end

      # `paths` (relative to head_root) limits the head side to these files, nil means all of them. `changed_lines`
      # (see .changed_lines) marks the findings on lines of the diff; nil counts every line as changed.
      def initialize(base_root:, head_root:, paths: nil, changed_lines: nil)
        @base_root = base_root.to_s
        @head_root = head_root.to_s
        @paths = paths
        @changed_lines = changed_lines
      end

      # One per file, series and organization
      def findings
        base_organizations = organizations(@base_root)
        base_uses = Hash.new { |hash, slug| hash[slug] = Set.new }
        references(@base_root).each { |reference| base_organizations[reference.slug]&.then { |organization| base_uses[organization.slug] << reference.series } }

        findings = references(@head_root, @paths).filter_map do |reference|
          organization = base_organizations[reference.slug]
          next if organization.nil? || base_uses[organization.slug].include?(reference.series)

          Finding.new(
            series: reference.series, slug: reference.slug, path: reference.path, line: reference.line,
            in_diff: @changed_lines.nil? || @changed_lines.fetch(reference.path, Set.new).include?(reference.line),
            name: organization["name"], website: organization["website"], other_series: base_uses[organization.slug].sort
          )
        end

        findings.group_by { |finding| [finding.path, finding.key] }.map { |_, same| same.find(&:in_diff) || same.first }
      end

      private

      # slug or alias slug => the organization
      def organizations(root)
        path = File.join(root, "data/organizations.yml")
        return {} if !File.file?(path) || File.symlink?(path)

        Static::Organization.in_file(path).each_with_object({}) do |organization, index|
          [organization.slug, *organization.alias_slugs].each { |slug| index[slug] = organization }
        end
      end

      def references(root, paths = nil)
        files = paths ? paths.map { |path| File.join(root, path) } : Dir.glob(File.join(root, "data/**/{sponsors,involvements}.yml"))

        files.select { |file| File.file?(file) && !File.symlink?(file) }.flat_map do |file|
          series = series_of(root, file)
          path = file.delete_prefix("#{root}/")

          if File.basename(file) == "sponsors.yml"
            Static::Sponsor.in_file(file).flat_map do |record|
              record.tiers.flat_map do |tier|
                tier.sponsors.map { |entry| Reference.new(series: series, slug: entry["slug"].to_s, path: path, line: entry.source_line("slug")) }
              end
            end
          else
            Static::Involvement.in_file(file).flat_map do |involvement|
              Array(involvement["organizations"]).each_with_index.map do |item, index|
                selector = item.is_a?(Hash) ? "organizations[#{index}].slug" : "organizations[#{index}]"
                slug = Yerba::Record::References.reference_value(item, "slug").to_s
                Reference.new(series: series, slug: slug, path: path, line: involvement.source_line(selector))
              end
            end
          end
        end
      end

      # A series' own file sits next to its series.yml; an event's file sits in a folder below it
      def series_of(root, file)
        folder = File.dirname(file)
        folder = File.dirname(folder) unless File.exist?(File.join(folder, "series.yml"))

        folder.delete_prefix("#{root}/")
      end
    end
  end
end
