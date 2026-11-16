# frozen_string_literal: true

class MunichRubyshiftImport
  # Writes YAML laid out like the data files after `yerba apply`: lists indented below their key, double-quoted
  # strings and literal blocks for text. It writes any value as it is, without a schema to check it against, since
  # `yerba apply` leaves a file that breaks its schema as it was.
  module YAMLWriter
    # Characters that a literal block can't hold, so text with them is written double-quoted.
    NOT_LITERAL = /[\p{Cc}&&[^\n\t]]|[\u0085﻿]/

    def self.write(path, value)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, dump(value))
    end

    def self.dump(value)
      "---\n#{lines(value, 0).join("\n")}\n"
    end

    def self.lines(value, indent)
      pad = " " * indent

      case value
      when Hash
        value.flat_map { |key, item| entry_lines("#{pad}#{key(key)}:", item, indent) }
      when Array
        value.flat_map do |item|
          next entry_lines("#{pad}-", item, indent) unless item.is_a?(Hash) && item.any?

          first, *rest = lines(item, indent + 2)
          ["#{pad}- #{first.lstrip}", *rest]
        end
      else
        ["#{pad}#{scalar(value)}"]
      end
    end

    def self.entry_lines(prefix, item, indent)
      if literal?(item)
        ["#{prefix} |-", *item.split("\n").map { |line| line.empty? ? "" : "#{" " * (indent + 2)}#{line}" }]
      elsif (item.is_a?(Hash) || item.is_a?(Array)) && item.any?
        [prefix, *lines(item, indent + 2)]
      else
        ["#{prefix} #{scalar(item)}"]
      end
    end

    # Multi-line text whose every character a literal block keeps as it is.
    def self.literal?(value)
      value.is_a?(String) && value.include?("\n") && !value.end_with?("\n") && !value.match?(/\A\n* /) && !value.match?(NOT_LITERAL)
    end

    def self.key(key)
      key.to_s.match?(/\A[\w-]+\z/) ? key.to_s : JSON.generate(key.to_s)
    end

    def self.scalar(value)
      case value
      when String, Hash, Array then JSON.generate(value)
      when nil then "null"
      else value.to_s
      end
    end
  end
end
