# frozen_string_literal: true

require "json"
require "time"

module Switchyard
  module CLI
    module_function

    def run(argv = ARGV)
      command = argv.first&.start_with?("-") ? "repos" : (argv.shift || "repos")
      args = parse_args(argv)
      config_path = args[:config] || Core::Config.default_config_path

      case command
      when "repos", "list", "ls", "status"
        run_repos_command(args, config_path)
      when "show", "info"
        run_show_command(args, config_path)
      when "start", "stop", "restart", "reload"
        run_control_command(command, args, config_path)
      when "enable", "disable"
        run_enable_command(command, args, config_path)
      when "reset-failed"
        run_reset_failed_command(args, config_path)
      when "logs", "journal"
        run_logs_command(args, config_path)
      when "refresh"
        run_refresh_command(args, config_path)
      when "open"
        run_open_command(args)
      when "panel", "ui"
        run_ui_command(command, args, config_path)
      when "waybar"
        run_waybar_command(args, config_path)
      when "daemon"
        Runtime::Daemon.run(config_path, once: args[:once])
        0
      when "config"
        run_config_command(args, config_path)
      when "help", "-h", "--help"
        puts help_text
        0
      else
        raise ArgumentError, "Unknown command: #{command}"
      end
    rescue StandardError => e
      warn "switchyard: #{e.message}"
      1
    end

    # Every branch returns an exit code; a branch that ends on a print would
    # otherwise hand `exit` a nil.
    def exit_code(value)
      value.is_a?(Integer) ? value : 0
    end

    def parse_args(argv)
      args = { format: "text", pretty: false, once: false, lines: nil, unit: nil, positionals: [] }
      index = 0
      while index < argv.length
        value = argv[index]
        case value
        when "--config"
          index += 1
          args[:config] = argv[index]
        when "--format"
          index += 1
          args[:format] = argv[index] == "json" ? "json" : "text"
        when "--json"
          args[:format] = "json"
        when "--pretty"
          args[:pretty] = true
        when "--once"
          args[:once] = true
        when "--lines", "-n"
          index += 1
          args[:lines] = argv[index].to_i
        when "--filter"
          index += 1
          args[:filter] = argv[index]
        when "--tab"
          index += 1
          args[:tab] = argv[index]
        else
          args[:positionals] << value
        end
        index += 1
      end
      args
    end

    # ---- read paths ----

    def run_repos_command(args, config_path)
      view = snapshot_view(args, config_path)
      if args[:format] == "json"
        print_json(view, args)
        return 0
      end

      summary = view[:summary]
      puts "Switchyard - Rails development environments (systemd)"
      puts "#{summary[:running]}/#{summary[:total]} running  ·  #{summary[:failing]} failing  ·  " \
           "#{summary[:ports]} listening  ·  #{summary[:restarts]} restarts  ·  scanned #{age_of(summary[:generatedAt])}"
      puts
      rows = view[:units]
      if rows.empty?
        puts "No Rails environments matched. Check servicePatterns and workdirMarkers in #{config_path}."
        return 0
      end

      name_width = [rows.map { |row| row[:unit].length }.max, 6].max
      puts format("%-#{name_width}s  %-16s %-18s %-7s %-7s %s", "UNIT", "KIND", "STATUS", "PORT", "PROBE", "WORKDIR")
      rows.each do |row|
        puts format(
          "%-#{name_width}s  %-16s %-18s %-7s %-7s %s",
          row[:unit],
          row[:kind],
          "#{row[:status]}#{row[:sinceBoot] ? ' (boot)' : ''}",
          row[:port] || "-",
          row[:probeUp] ? "http #{row[:probeStatus] || 'up'}" : "-",
          row[:appRoot] || row[:workdir] || "-"
        )
      end
      alerts = view[:alerts]
      unless alerts.empty?
        puts
        alerts.each { |alert| puts "! #{alert}" }
      end
      0
    end

    def run_show_command(args, config_path)
      unit = args[:positionals].first || args[:unit]
      raise ArgumentError, "show requires a unit name." if unit.to_s.empty?

      view = snapshot_view(args, config_path)
      row = view[:units].find { |candidate| candidate[:unit] == unit }
      raise ArgumentError, "#{unit} is not one of the detected Rails environments." if row.nil?

      if args[:format] == "json"
        print_json(row, args)
        return 0
      end

      puts "#{row[:unit]}  [#{row[:kind]}]"
      puts "  #{row[:description]}"
      puts "  status      #{row[:status]} (#{row[:activeState]}/#{row[:subState]})"
      puts "  enabled     #{row[:enabled]} (#{row[:unitFileState]})"
      puts "  restarts    #{row[:restarts]}"
      puts "  started     #{row[:uptimeText] ? "#{row[:uptimeText]} ago" : 'never'}#{row[:sinceBoot] ? ' - at boot' : ''}"
      puts "  main pid    #{row[:mainPid].positive? ? row[:mainPid] : '-'}"
      puts "  user        #{row[:user].to_s.empty? ? '-' : row[:user]}"
      puts "  memory      #{row[:memoryText] || '-'}   cpu #{row[:cpuSeconds]}s"
      puts "  workdir     #{row[:workdir].to_s.empty? ? '-' : row[:workdir]}"
      puts "  app root    #{row[:appRoot] || '(not a Rails app)'}"
      if row[:port]
        puts "  port        #{row[:port]} on #{row[:portAddress]} (#{row[:portCommand]})"
        puts "  probe       #{row[:probeUp] ? "answered #{row[:probeStatus] || 'up'} in #{row[:probeConnectMs]}ms" : 'no listener answered'}"
        puts "  url         #{row[:url]}"
      else
        puts "  port        none listening"
      end
      puts "  signals     #{Array(row[:signals]).join(', ')}"
      puts "  unit file   #{row[:fragmentPath].to_s.empty? ? '-' : row[:fragmentPath]}"
      0
    end

    def snapshot_view(args, config_path)
      config = Core::Config.load_config(config_path)
      snapshot = Runtime::State.read_snapshot(config)
      if snapshot.nil?
        Runtime::Daemon.dispatch_action(config_path, type: "refresh")
        raise "switchyard has no snapshot yet and the daemon could not produce one." unless Runtime::State.read_snapshot(config)

        return Runtime::State.read_snapshot(config)[:view]
      end

      snapshot[:view] || Runtime::Presenter.build_view(config, snapshot[:units] || [])
    end

    def age_of(timestamp)
      text = Core::Format.age_text(timestamp)
      text ? "#{text} ago" : "never"
    end

    # ---- mutations ----

    def run_control_command(command, args, config_path)
      unit = args[:positionals].first || args[:unit]
      raise ArgumentError, "#{command} requires a unit name." if unit.to_s.empty?

      result = Runtime::Daemon.dispatch_action(config_path, type: command, unit: unit)
      return finish_action(result, args) unless result[:ok]

      # A mutation always changes what the next scan will see; run one now so
      # the panel and the chip are not a whole refresh interval behind the click.
      Runtime::Daemon.dispatch_action(config_path, type: "refresh")
      finish_action(result, args) { "systemctl: #{result[:action]} #{result[:unit]}" }
    end

    def run_enable_command(command, args, config_path)
      unit = args[:positionals].first || args[:unit]
      raise ArgumentError, "#{command} requires a unit name." if unit.to_s.empty?

      result = Runtime::Daemon.dispatch_action(config_path, type: command, unit: unit)
      Runtime::Daemon.dispatch_action(config_path, type: "refresh") if result[:ok]
      finish_action(result, args) { "systemctl: #{result[:action]} #{result[:unit]}" }
    end

    def run_reset_failed_command(args, config_path)
      unit = args[:positionals].first || args[:unit]
      raise ArgumentError, "reset-failed requires a unit name." if unit.to_s.empty?

      result = Runtime::Daemon.dispatch_action(config_path, type: "reset_failed", unit: unit)
      Runtime::Daemon.dispatch_action(config_path, type: "refresh") if result[:ok]
      finish_action(result, args) { "systemctl: #{result[:action]} #{result[:unit]}" }
    end

    def finish_action(result, args)
      if args[:format] == "json"
        print_json(result, args)
        return result[:ok] ? 0 : 1
      end

      if result[:ok]
        puts block_given? ? yield : "#{result[:action]} #{result[:unit]}"
        0
      else
        warn "#{result[:action]} #{result[:unit]} failed: #{result[:error]}"
        1
      end
    end

    def run_logs_command(args, config_path)
      unit = args[:positionals].first || args[:unit]
      raise ArgumentError, "logs requires a unit name." if unit.to_s.empty?

      config = Core::Config.load_config(config_path)
      lines = args[:lines].to_i.positive? ? args[:lines].to_i : config[:logLines]
      result = Core::Systemd.journal(config, unit, lines: lines)
      raise "could not read the journal for #{unit}: #{result[:error]}" if result[:error]

      if args[:format] == "json"
        print_json(result, args)
      else
        puts result[:lines]
      end
      0
    end

    def run_refresh_command(args, config_path)
      Runtime::Daemon.dispatch_action(config_path, type: "refresh")
      config = Core::Config.load_config(config_path)
      deadline = Time.now + 15
      sleep 0.1 while Runtime::State.read_snapshot(config).nil? && Time.now < deadline
      view = snapshot_view(args, config_path)
      args[:format] == "json" ? print_json(view, args) : puts(Runtime::Presenter.summary_text(view))
      0
    end

    def run_open_command(args)
      target = args[:positionals].first
      raise ArgumentError, "open requires a URL or path." if target.to_s.strip.empty?

      Core::Process.spawn_detached("xdg-open", [target])
      0
    end

    # ---- UI ----

    def run_ui_command(command, args, config_path)
      subcommand = command == "panel" ? "open" : (args[:positionals].first || "open")
      payload = case subcommand
                when "open" then Runtime::QuickShell.open(config_path, args[:positionals][1])
                when "close" then Runtime::QuickShell.close(config_path)
                when "toggle" then Runtime::QuickShell.toggle(config_path, args[:positionals][1])
                when "status" then Runtime::QuickShell.status(config_path)
                when "select" then Runtime::Store.select_unit(config_path, args[:positionals][1].to_s)
                when "filter" then Runtime::Store.set_filter(config_path, args[:positionals][1].to_s)
                when "filter-query" then Runtime::Store.set_query(config_path, args[:positionals][1].to_s)
                when "tab" then Runtime::Store.set_detail_tab(config_path, args[:positionals][1].to_s)
                else raise ArgumentError, "Unknown ui subcommand: #{subcommand}"
                end
      args[:format] == "json" ? print_json(payload, args) : puts(JSON.generate(payload))
      0
    end

    def run_waybar_command(args, config_path)
      subcommand = args[:positionals].first || "render"
      case subcommand
      when "render" then Runtime::Waybar.render(config_path)
      when "refresh" then Runtime::Daemon.dispatch_action(config_path, type: "refresh")
      when "panel", "open" then Runtime::QuickShell.open(config_path)
      else raise ArgumentError, "Unknown waybar subcommand: #{subcommand}"
      end
      0
    end

    def run_config_command(args, config_path)
      subcommand = args[:positionals].first || "show"
      case subcommand
      when "init"
        Runtime::State.ensure_ui_state(Core::Config.load_config(config_path))
        config = Core::Config.save_config(Core::Config.default_config, config_path)
        puts("Wrote #{config_path}")
      when "show"
        config = Core::Config.load_config(config_path)
        args[:format] == "json" ? print_json(config, args) : puts(JSON.pretty_generate(config))
      when "validate"
        config = Core::Config.load_config(config_path)
        issues = Core::Config.validate_config(config, config_path: config_path)
        if args[:format] == "json"
          print_json({ configPath: config_path, issues: issues }, args)
        elsif issues.empty?
          puts "#{config_path} is valid."
        else
          issues.each { |issue| puts "#{issue[:severity]}: #{issue[:field]} - #{issue[:message]}" }
        end
        return issues.any? { |issue| issue[:severity] == "error" } ? 1 : 0
      else
        raise ArgumentError, "Unknown config subcommand: #{subcommand}"
      end
      0
    end

    def print_json(payload, args)
      puts(args[:pretty] ? JSON.pretty_generate(payload) : JSON.generate(payload))
    end

    def help_text
      <<~HELP
        switchyard - manage Rails development environments on this host through systemd

        Usage: switchyard [command] [options]

        Read:
          repos                     List detected Rails environments (default)
          show UNIT                 Everything known about one environment
          logs UNIT [--lines N]     Tail the unit journal
          status                    Alias for repos

        Control:
          start|stop|restart|reload UNIT     systemctl action, then a scan
          enable|disable UNIT                Enable or disable at boot
          reset-failed UNIT                  Clear a crash-loop counter
          refresh                            Force a scan now

        Surface:
          panel                     Open the QuickShell dashboard
          ui open|close|toggle|status
          waybar render|refresh|panel
          daemon [--once]           Run the action daemon (or one scan)
          open URL                  Open a URL in the browser

        Config:
          config init|show|validate

        Options: --config PATH  --json  --pretty  --lines N  --filter K  --tab K
      HELP
    end
  end
end
