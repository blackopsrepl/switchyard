# frozen_string_literal: true

require "shellwords"

module Switchyard
  module Core
    # Reads and controls systemd units through the systemctl binary.
    #
    # Two things matter here:
    #
    # * `systemctl show` is the source of truth, not `list-units`. It reports
    #   ActiveState, SubState, NRestarts and ExecMainStartTimestampMonotonic for
    #   every unit, including ones that are crash-looping, without an extra
    #   privilege prompt.
    # * Mutations go through the configured prefix (`sudo -n` by default) so a
    #   dashboard click can never hang on a password prompt.
    module Systemd
      SHOW_PROPERTIES = %w[
        Id
        Description
        ActiveState
        SubState
        LoadState
        UnitFileState
        MainPID
        NRestarts
        ActiveEnterTimestamp
        ActiveEnterTimestampMonotonic
        ExecMainStartTimestampMonotonic
        WorkingDirectory
        User
        Group
        FragmentPath
        ExecStart
        Environment
        MemoryCurrent
        CPUUsageNSec
      ].freeze

      module_function

      def show(config, units)
        ids = Array(units).map(&:to_s).reject(&:empty?)
        return {} if ids.empty?

        bin, prefix_args = command_parts(config)
        # Batched: a single argv with every unit on a large host overflows the
        # argument list, and one un-showable name would otherwise fail the whole
        # call and silently report "no environments".
        ids.each_slice(SHOW_BATCH).each_with_object({}) do |batch, acc|
          result = Core::Process.run(bin, prefix_args + show_args(config, batch))
          next unless result.success?

          acc.merge!(parse_show(result.stdout))
        end
      end

      SHOW_BATCH = 64

      # Resolving the glob ourselves, instead of letting systemctl expand it.
      # `systemctl show '*.service'` only ever matches units systemd currently
      # has loaded, so an installed-but-never-started unit (exactly the dev
      # environments this dashboard is for) is invisible to it. The union of
      # installed unit files and the loaded set is the honest candidate list.
      # Uninstantiated templates (`autovt@.service`) cannot be shown and are
      # dropped here rather than poisoning a batch.
      def unit_names(config, patterns)
        names = list_names(config, ["list-unit-files", "--type=service"]) |
                list_names(config, ["list-units", "--all", "--type=service"])
        globs = Array(patterns).map(&:to_s).reject(&:empty?)
        names = names.reject { |name| name.match?(/@\.service\z/) }
        return names.sort if globs.empty?

        names.select { |name| globs.any? { |glob| File.fnmatch?(glob, name) } }.sort
      end

      def list_names(config, argv)
        bin, prefix_args = command_parts(config)
        result = Core::Process.run(bin, prefix_args + argv + ["--no-legend", "--no-pager"])
        return [] unless result.success?

        result.stdout.each_line.filter_map do |line|
          name = line.split(/\s+/).first
          name if name.to_s.end_with?(".service")
        end
      rescue StandardError
        []
      end

      def show_args(config, units)
        ids = Array(units).map(&:to_s).reject(&:empty?)
        return nil if ids.empty?

        argv = ["show", "-p", SHOW_PROPERTIES.join(","), "--no-pager"]
        argv += (ids.length == 1 ? [] : ["--"]) + ids
        argv
      end

      # A single mutation. Returns { ok:, action:, unit:, error: }.
      def control(config, action, unit)
        verb = { start: "start", stop: "stop", restart: "restart", reload: "reload" }[action.to_sym]
        return { ok: false, action: action.to_s, unit: unit, error: "Unsupported action." } unless verb
        return { ok: false, action: verb, unit: unit, error: "Unit name required." } if unit.to_s.strip.empty?

        bin, prefix_args = command_parts(config)
        result = Core::Process.run(bin, prefix_args + [verb, unit.to_s])

        { ok: result.success?, action: verb, unit: unit.to_s, error: result.success? ? nil : result.output.to_s.strip }
      end

      def enable(config, unit, enabled: true)
        bin, prefix_args = command_parts(config)
        result = Core::Process.run(bin, prefix_args + [enabled ? "enable" : "disable", unit.to_s])
        { ok: result.success?, action: enabled ? "enable" : "disable", unit: unit.to_s, error: result.success? ? nil : result.output.to_s.strip }
      end

      def reset_failed(config, unit)
        bin, prefix_args = command_parts(config)
        result = Core::Process.run(bin, prefix_args + ["reset-failed", unit.to_s])
        { ok: result.success?, action: "reset-failed", unit: unit.to_s, error: result.success? ? nil : result.output.to_s.strip }
      end

      def journal(config, unit, lines:)
        bin, prefix_args = command_parts(config, journal: true)
        result = Core::Process.run(bin, prefix_args + ["-u", unit.to_s, "-n", lines.to_i.to_s, "--no-pager", "-o", "short-iso"])
        {
          unit: unit.to_s,
          lines: result.success? ? result.stdout.to_s.split("\n") : [],
          error: result.success? ? nil : result.output.to_s.strip
        }
      end

      # The prefix contributes its executable as well as its flags: a prefix of
      # `sudo -n` plus a bin of `systemctl` must run `sudo -n systemctl …`, not
      # `systemctl -n …` (which silently fails and looks like "no units").
      def command_parts(config, journal: false)
        words = Shellwords.split(config[journal ? :journalctlPrefix : :systemctlPrefix].to_s) +
                Shellwords.split(config[journal ? :journalctlBin : :systemctlBin].to_s)
        return [nil, []] if words.empty?

        [words.first, words[1..] || []]
      end

      # systemctl show prints `Key=Value` blocks separated by a blank line.
      def parse_show(text)
        blocks = text.to_s.split(/\n\s*\n/)
        blocks.each_with_object({}) do |block, acc|
          fields = {}
          block.each_line do |line|
            key, value = line.chomp.split("=", 2)
            next if key.nil? || key.empty?

            fields[key] = value
          end
          id = fields["Id"]
          next if id.nil? || id.empty?

          acc[id] = fields
        end
      end

      # `{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec rails server -p 3004 ; … }`
      def exec_argv(exec_start)
        text = exec_start.to_s
        match = text.match(/argv\[\]=(.*?)\s*;/m)
        return [] if match.nil?

        Shellwords.split(match[1].to_s.strip)
      rescue ArgumentError
        []
      end

      def exec_path(exec_start)
        match = exec_start.to_s.match(/path=(\S+)/)
        match && match[1]
      end

      def environment_hash(environment)
        environment.to_s.split(/\s+/).each_with_object({}) do |pair, acc|
          key, value = pair.split("=", 2)
          next if key.nil? || key.empty?

          acc[key] = value.to_s
        end
      end

      # Prefers ActiveEnterTimestamp, then the monotonic exec stamp (which is
      # the only uptime signal for a unit that is crash-looping).
      def start_timestamp(fields, now: Time.now)
        explicit = fields["ActiveEnterTimestamp"].to_s.strip
        return explicit unless explicit.empty? || explicit == "n/a"

        monotonic = fields["ExecMainStartTimestampMonotonic"].to_i
        return nil if monotonic <= 0

        uptime_us = monotonic_uptime_us
        return nil if uptime_us.nil?

        (now - ((uptime_us - monotonic) / 1_000_000.0)).utc.iso8601
      end

      def monotonic_uptime_us
        File.read("/proc/uptime").split.first.to_f * 1_000_000
      rescue StandardError
        nil
      end
    end
  end
end
