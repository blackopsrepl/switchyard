# frozen_string_literal: true

require "time"

module Switchyard
  module Runtime
    # Turns raw unit rows into the single projection the panel, the CLI and the
    # Waybar chip all render, so they cannot disagree about a status.
    module Presenter
      # How long a unit has to have been up before a start is allowed to be
      # called "since boot". A short uptime means everything is "since boot",
      # which is exactly what made "restarts 2413" and "since boot" disagree.
      BOOT_WINDOW_SECONDS = 300

      # Restarts per minute since boot above which a unit is considered to be
      # cycling rather than merely restarted.
      CYCLING_RESTARTS_PER_MINUTE = 1.0

      STATUS_TONE = {
        "running" => "good",
        "reloading" => "info",
        "stopped" => "muted",
        "crash-loop" => "bad",
        "failed" => "bad",
        "unknown" => "warn"
      }.freeze

      module_function

      def build_view(config, rows, now = Time.now, uptime: host_uptime_seconds)
        units = rows.map { |row| unit_view(config, row, now, uptime: uptime) }
        summary = {
          total: units.length,
          running: units.count { |unit| unit[:status] == "running" || unit[:status] == "reloading" },
          stopped: units.count { |unit| unit[:status] == "stopped" },
          failing: units.count { |unit| unit[:status] == "crash-loop" || unit[:status] == "failed" },
          restarts: units.sum { |unit| unit[:restarts].to_i },
          probes: units.count { |unit| unit[:probeUp] },
          ports: units.count { |unit| unit[:port] },
          generatedAt: now.utc.iso8601
        }
        {
          summary: summary,
          alerts: alerts(units),
          units: units,
          chip: chip(summary)
        }
      end

      def unit_view(config, row, now = Time.now, uptime: host_uptime_seconds)
        status = status_of(row, now, uptime: uptime)
        {
          unit: row[:unit],
          kind: row[:kind],
          description: row[:description],
          activeState: row[:activeState],
          subState: row[:subState],
          status: status,
          tone: STATUS_TONE.fetch(status, "muted"),
          enabled: row[:unitFileState].to_s == "enabled",
          unitFileState: row[:unitFileState],
          loadState: row[:loadState],
          restarts: row[:restarts].to_i,
          mainPid: row[:mainPid].to_i,
          user: row[:user],
          workdir: row[:workdir],
          appRoot: row[:appRoot],
          railsApp: row[:railsApp],
          signals: row[:signals],
          override: row[:override],
          memoryBytes: row[:memoryBytes].to_i,
          memoryText: Core::Format.bytes_text(row[:memoryBytes]),
          cpuSeconds: row[:cpuSeconds],
          startedAt: row[:startedAt],
          uptimeText: Core::Format.age_text(row[:startedAt], now),
          sinceBoot: since_boot?(row, now, uptime: uptime),
          fragmentPath: row[:fragmentPath].to_s,
          port: row[:port],
          portAddress: row[:portAddress],
          portCommand: row[:portCommand],
          portPids: row[:portPids],
          listening: !row[:port].nil?,
          probeUp: !row[:probe].nil?,
          probeStatus: row[:probe] && row[:probe][:status],
          probeConnectMs: row[:probe] && row[:probe][:connectMs],
          url: row[:port] ? "http://127.0.0.1:#{row[:port]}/" : nil
        }
      end

      def status_of(row, now = Time.now, uptime: host_uptime_seconds)
        # Cycling outranks the transient state: a unit in the middle of a restart
        # storm is not "running" just because its last start got as far as exec.
        return "crash-loop" if cycling?(row, now, uptime: uptime)

        active = row[:activeState].to_s
        sub = row[:subState].to_s
        case active
        when "active" then "running"
        when "reloading" then "reloading"
        when "activating" then sub == "auto-restart" ? "crash-loop" : "running"
        when "failed" then row[:unitFileState].to_s == "enabled" ? "crash-loop" : "failed"
        when "inactive" then sub == "dead" ? "stopped" : "unknown"
        when "deactivating" then "reloading"
        else "unknown"
        end
      end

      # A unit systemd has restarted more than CYCLING_RESTARTS_PER_MINUTE times
      # per minute since boot is cycling. NRestarts is per unit load, and units
      # are loaded at boot, so NRestarts / uptime is a real rate.
      #
      # This exists because the transient is not catchable: a unit whose
      # ExecStart dies in a few hundred milliseconds alternates between
      # `activating/auto-restart` and `active/running`, and a 10-second scan
      # catches `active/running` often enough to make a permanently broken
      # environment flicker into the healthy count. The counter only grows, so
      # the rate is the stable signal.
      def cycling?(row, now = Time.now, uptime: host_uptime_seconds)
        return false unless row[:restarts].to_i.positive?
        return false unless uptime.positive?

        (row[:restarts].to_i / (uptime / 60.0)) >= CYCLING_RESTARTS_PER_MINUTE
      end

      # A unit started seconds after the host booted has no meaningful uptime:
      # its start stamp came from the boot, not from anyone asking for it.
      def since_boot?(row, now, uptime: host_uptime_seconds)
        started = Core::Format.parse_time(row[:startedAt])
        return false if started.nil?

        booted_at = now - uptime
        started <= booted_at + BOOT_WINDOW_SECONDS
      end

      def host_uptime_seconds
        File.read("/proc/uptime").split.first.to_f
      rescue StandardError
        0.0
      end

      def alerts(units)
        units.filter_map do |unit|
          restarts = unit[:restarts].to_i
          case unit[:status]
          when "crash-loop"
            "#{unit[:unit]}: crash-looping (#{restarts} restarts#{unit[:uptimeText] ? ", #{unit[:uptimeText]} ago" : ''})"
          when "failed"
            "#{unit[:unit]}: failed (and not enabled to restart)"
          else
            if restarts >= 5 && unit[:status] == "running"
              "#{unit[:unit]}: #{restarts} restarts before the current run"
            end
          end
        end
      end

      def chip(summary)
        failing = summary[:failing].to_i
        text = if summary[:total].zero?
                 "..."
               elsif failing.positive?
                 "#{summary[:running]}/#{summary[:total]} #{failing} failing"
               else
                 "#{summary[:running]}/#{summary[:total]} up"
               end
        classes = ["switchyard"]
        classes << (summary[:total].zero? ? "loading" : "healthy")
        classes << "has-failures" if failing.positive?
        classes << "has-restarts" if summary[:restarts].to_i.positive?
        {
          text: text,
          tooltipLines: [
            "Switchyard - Rails dev environments",
            "#{summary[:running]} of #{summary[:total]} running",
            "#{summary[:ports]} listening port#{summary[:ports] == 1 ? '' : 's'}",
            failing.positive? ? "#{failing} failing: run 'switchyard repos'" : "no failing units",
            "Left click: panel  ·  Right click: status"
          ],
          classes: classes
        }
      end

      def summary_text(view)
        summary = view[:summary]
        "#{summary[:running]}/#{summary[:total]} running  ·  #{summary[:failing]} failing  ·  #{summary[:restarts]} restarts"
      end
    end
  end
end
