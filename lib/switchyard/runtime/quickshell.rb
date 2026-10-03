# frozen_string_literal: true

module Switchyard
  module Runtime
    # Launches the QuickShell panel and reads the panel's own intent file back.
    module QuickShell
      module_function

      def open(config_path, unit = nil)
        config = Core::Config.load_config(config_path)
        Daemon.dispatch_action(config_path, type: "open_panel", unit: unit.to_s)
        ensure_running(config, config_path)
        status(config_path)
      end

      def close(config_path)
        Daemon.dispatch_action(config_path, type: "close_panel")
        status(config_path)
      end

      def toggle(config_path, unit = nil)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:open] ? close(config_path) : open(config_path, unit)
      end

      def status(config_path)
        config = Core::Config.load_config(config_path)
        {
          ui: State.read_ui_state(config),
          snapshotPath: State.snapshot_path(config),
          uiPath: State.ui_state_path(config),
          logPath: State.log_state_path(config),
          stateEventPath: State.state_event_path(config),
          quickShellRunning: running?(config)
        }
      end

      def ensure_running(config, config_path)
        return if running?(config)

        command = config.dig(:runtime, :quickShellCommand)
        shell = File.expand_path(config.dig(:runtime, :quickShellShell))
        env = {
          "SWITCHYARD_BIN" => executable,
          "SWITCHYARD_CONFIG" => File.expand_path(config_path),
          "SWITCHYARD_STATE_DIR" => State.state_dir(config),
          "QS_NO_RELOAD_POPUP" => "1",
          "QT_QPA_PLATFORM" => "wayland"
        }
        Core::Process.spawn_detached(command, ["--daemonize", "--no-duplicate", "--path", shell], env: env, cwd: File.dirname(shell))
      end

      def running?(config = nil)
        shell_path = File.expand_path(config&.dig(:runtime, :quickShellShell) || Core::Config.default_quickshell_shell)
        result = Core::Process.run("ps", ["-eo", "comm=,args="])
        result.success? && result.stdout.lines.any? do |line|
          command, args = line.strip.split(/\s+/, 2)
          command == "quickshell" && args.to_s.include?(shell_path)
        end
      rescue StandardError
        false
      end

      def executable
        candidates = [
          File.expand_path("../../../bin/switchyard", __dir__),
          File.join(Dir.home, ".local", "bin", "switchyard")
        ]
        candidates.find { |candidate| File.executable?(candidate) } || "switchyard"
      end
    end
  end
end
