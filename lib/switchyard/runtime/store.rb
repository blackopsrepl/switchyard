# frozen_string_literal: true

require "time"

module Switchyard
  module Runtime
    # Owns every state transition. The CLI and the panel both dispatch here;
    # neither reads systemd or writes the snapshot on its own.
    module Store
      module_function

      def scan_effect(config_path)
        config = Core::Config.load_config(config_path)
        State.with_scan_lock(config) do
          units = Core::Systemd.unit_names(config, unit_glob(config))
          fields = Core::Systemd.show(config, units)
          environments = fields.values.filter_map { |unit_fields| Core::Detect.classify(config, unit_fields) }
          Core::Detect.sort(environments)

          ports = Core::Ports.scan
          now = Time.now
          rows = environments.map { |env| build_row(config, env, fields[env[:unit]], ports, now) }

          snapshot = {
            snapshotVersion: State::SNAPSHOT_VERSION,
            generatedAt: now.utc.iso8601,
            config: {
              refreshSeconds: config.dig(:runtime, :refreshSeconds),
              stateDir: State.state_dir(config),
              systemctlPrefix: config[:systemctlPrefix]
            },
            view: Presenter.build_view(config, rows, now)
          }
          State.write_snapshot(config, snapshot)
          snapshot
        end
      end

      def unit_glob(config)
        Array(config[:servicePatterns]).map { |pattern| pattern.to_s }
      end

      def build_row(config, env, fields, ports, now)
        fields ||= {}
        unit = env[:unit]
        pids = Core::Ports.unit_pids(unit)
        port = ports.values.find { |candidate| pids.include?(candidate[:pid]) }

        probe = port ? Core::Probe.probe(config, port[:port], host: port[:host]) : nil

        env.merge(
          activeState: fields["ActiveState"].to_s,
          subState: fields["SubState"].to_s,
          loadState: fields["LoadState"].to_s,
          unitFileState: fields["UnitFileState"].to_s,
          mainPid: fields["MainPID"].to_i,
          restarts: fields["NRestarts"].to_i,
          startedAt: Core::Systemd.start_timestamp(fields, now: now),
          fragmentPath: fields["FragmentPath"].to_s,
          memoryBytes: fields["MemoryCurrent"].to_i,
          cpuSeconds: (fields["CPUUsageNSec"].to_i / 1_000_000_000.0).round(2),
          user: fields["User"].to_s,
          port: port ? port[:port] : nil,
          portAddress: port ? port[:address] : nil,
          portCommand: port ? port[:command] : nil,
          portPids: pids,
          probe: probe
        )
      end

      def fetch_logs_effect(config_path, unit)
        config = Core::Config.load_config(config_path)
        state = {
          unit: unit.to_s,
          status: "loading",
          lines: [],
          error: "",
          updatedAt: Time.now.utc.iso8601
        }
        State.write_log_state(config, state)

        result = Core::Systemd.journal(config, unit, lines: config[:logLines])
        state = state.merge(
          status: result[:error] ? "error" : "ready",
          lines: result[:lines],
          error: result[:error].to_s,
          updatedAt: Time.now.utc.iso8601
        )
        State.write_log_state(config, state)
        state
      end

      def open_panel(config_path, unit = nil)
        config = Core::Config.load_config(config_path)
        State.ensure_ui_state(config)
        state = State.read_ui_state(config)
        state[:open] = true
        state[:selectedUnit] = unit.to_s if unit && !unit.to_s.empty?
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def close_panel(config_path)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:open] = false
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def select_unit(config_path, unit)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:selectedUnit] = unit.to_s
        state[:detailTab] = "overview"
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def set_filter(config_path, filter)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:filter] = filter.to_s
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def set_query(config_path, query)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:query] = query.to_s
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def set_detail_tab(config_path, tab)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:detailTab] = tab.to_s
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def control_unit(config_path, action, unit)
        config = Core::Config.load_config(config_path)
        Core::Systemd.control(config, action, unit)
      end

      def toggle_enabled(config_path, unit)
        config = Core::Config.load_config(config_path)
        fields = Core::Systemd.show(config, [unit])
        current = fields.dig(unit, "UnitFileState").to_s
        Core::Systemd.enable(config, unit, enabled: current != "enabled")
      end

      def set_enabled(config_path, unit, enabled:)
        config = Core::Config.load_config(config_path)
        Core::Systemd.enable(config, unit, enabled: enabled)
      end

      def reset_failed(config_path, unit)
        config = Core::Config.load_config(config_path)
        Core::Systemd.reset_failed(config, unit)
      end

      def signal_waybar(config)
        signal = config.dig(:runtime, :waybarSignal).to_i
        return unless signal.positive?

        Core::Process.run("pkill", ["-RTMIN+#{signal}", "-x", "waybar"])
      rescue StandardError
        nil
      end

      def timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
