# frozen_string_literal: true

module Static
  module Validators
    # An organization is listed at most once per sponsorship tier or involvement role, counted the way the import
    # matches them: two entries the import would merge into one record (or reject, for an event) are a mistake in the
    # file, often left behind after a slug became an alias. In a series' file, entries starting on different dates are
    # separate periods and allowed; an event's sponsors and roles have no periods.
    class UniqueOrganizationReferences
      PATTERNS = ["**/sponsors.yml", "**/involvements.yml"].freeze

      Listing = Data.define(:label, :slug, :from, :line)

      def initialize(file_path:, document: nil)
        @file_path = file_path.to_s.sub("#{Rails.root}/", "")
        @document = document
      end

      def applicable?
        return false unless File.exist?(@file_path)

        PATTERNS.any? do |pattern|
          File.fnmatch?(pattern, @file_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
        end
      end

      def errors
        @errors ||= validate
      end

      def validate
        return [] unless applicable?

        listings.group_by { |listing| [listing.label, current_slug(listing.slug), period_start(listing.from)] }.filter_map do |(label, slug, _), duplicates|
          next if duplicates.one?

          Static::Validators::Error.new(message(label, slug, duplicates), file_path: @file_path, line: duplicates[1].line || 1)
        end
      end

      private

      def listings
        if File.basename(@file_path) == "sponsors.yml"
          Static::Sponsor.in_file(@file_path, document: @document).flat_map do |record|
            record.tiers.flat_map do |tier|
              label = tier["name"].present? ? %(tier "#{tier["name"]}") : "the unnamed tier"
              tier.sponsors.map { |entry| Listing.new(label: label, slug: entry["slug"], from: entry["from"], line: entry.source_line("slug")) }
            end
          end
        else
          Static::Involvement.in_file(@file_path, document: @document).flat_map do |involvement|
            Array(involvement["organizations"]).each_with_index.map do |item, index|
              selector = item.is_a?(Hash) ? "organizations[#{index}].slug" : "organizations[#{index}]"
              from = item.is_a?(Hash) ? item["from"] : nil

              Listing.new(label: %(role "#{involvement["name"]}"), slug: Yerba::Record::References.reference_value(item, "slug"), from: from, line: involvement.source_line(selector))
            end
          end
        end
      end

      def message(label, slug, duplicates)
        used = duplicates.map(&:slug).uniq
        message = %(Organization "#{slug}" is listed #{duplicates.size} times in #{label})
        message += %( (as #{used.map { |value| %("#{value}") }.join(" and ")})) if used.size > 1

        message
      end

      # The import keys series entries by their start date; events have no periods
      def period_start(from)
        ::Sponsor.period_start(from) if series_file?
      end

      def series_file?
        File.exist?(File.join(File.dirname(@file_path), "series.yml"))
      end

      def current_slug(slug)
        Static::Organization.find_by(slug: slug.to_s)&.slug || slug
      end
    end
  end
end
