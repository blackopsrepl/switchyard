# frozen_string_literal: true

require "time"

module Switchyard
  module Core
    module Format
      module_function

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        text = value.to_s.strip
        return nil if text.empty? || text == "n/a"

        Time.parse(text)
      rescue ArgumentError
        nil
      end

      def iso(time)
        return nil if time.nil?

        time.utc.iso8601
      end

      def age_seconds(value, now = Time.now)
        time = parse_time(value)
        return nil if time.nil?

        (now - time).to_i
      end

      # Compact age: 45s, 12m, 3h, 6d.
      def age_text(value, now = Time.now)
        seconds = age_seconds(value, now)
        return nil if seconds.nil?

        duration_text(seconds)
      end

      def duration_text(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end

      def bytes_text(bytes)
        value = bytes.to_i
        return nil if value <= 0
        return "#{value} B" if value < 1024
        return format("%.1f KiB", value / 1024.0) if value < 1024 * 1024

        format("%.1f MiB", value / (1024.0 * 1024))
      end

      def pluralize(count, singular, plural = nil)
        "#{count} #{count == 1 ? singular : (plural || "#{singular}s")}"
      end
    end
  end
end
