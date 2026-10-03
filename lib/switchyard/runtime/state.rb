# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Switchyard
  module Runtime
    # Cached JSON state. One snapshot the panel renders, one ui.json it writes
    # intent into, plus a log tail per unit fetched on demand.
    module State
      SNAPSHOT_VERSION = 1
      SNAPSHOT_FILE = "snapshot.json"
      UI_STATE_FILE = "ui.json"
      LOG_STATE_FILE = "log.json"
      STATE_EVENT_FILE = "state-event.json"
      DAEMON_LOCK_FILE = "daemon.lock"
      DAEMON_SOCKET_FILE = "daemon.sock"
      SCAN_LOCK_FILE = "scan.lock"

      module_function

      # Every file this tool reads is UTF-8 JSON. Naming the encoding is not
      # decoration: under a C/POSIX locale Ruby tags File.read content US-ASCII,
      # and JSON's C parser then raises InvalidByteSequenceError on the first
      # non-ASCII byte — which made every snapshot read fail for any daemon
      # started outside an interactive shell (systemd --user has no UTF-8 locale).
      def read_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: Encoding::UTF_8), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def state_dir(config)
        File.expand_path(config.dig(:runtime, :stateDir))
      end

      def snapshot_path(config)
        File.join(state_dir(config), SNAPSHOT_FILE)
      end

      def ui_state_path(config)
        File.join(state_dir(config), UI_STATE_FILE)
      end

      def log_state_path(config)
        File.join(state_dir(config), LOG_STATE_FILE)
      end

      def state_event_path(config)
        File.join(state_dir(config), STATE_EVENT_FILE)
      end

      def daemon_socket_path(config)
        File.join(state_dir(config), DAEMON_SOCKET_FILE)
      end

      def read_snapshot(config)
        read_json(snapshot_path(config))
      end

      def write_snapshot(config, snapshot)
        ensure_state_dir(config)
        atomic_write_json(snapshot_path(config), snapshot)
        notify_state_change(config)
      end

      def read_ui_state(config)
        normalize_ui_state(read_json(ui_state_path(config)) || {})
      end

      def write_ui_state(config, ui_state)
        ensure_state_dir(config)
        atomic_write_json(ui_state_path(config), normalize_ui_state(ui_state))
        notify_state_change(config)
      end

      def read_log_state(config)
        normalize_log_state(read_json(log_state_path(config)) || {})
      end

      def write_log_state(config, log_state)
        ensure_state_dir(config)
        atomic_write_json(log_state_path(config), normalize_log_state(log_state))
        notify_state_change(config)
      end

      def default_ui_state
        {
          open: false,
          selectedUnit: "",
          filter: "all",
          query: "",
          detailTab: "overview",
          requestedAt: ""
        }
      end

      def default_log_state
        {
          unit: "",
          status: "idle",
          lines: [],
          error: "",
          updatedAt: ""
        }
      end

      def normalize_ui_state(ui_state)
        state = default_ui_state.merge((ui_state || {}).transform_keys(&:to_sym))
        filter = %w[all running stopped failed].include?(state[:filter].to_s) ? state[:filter].to_s : "all"
        tab = %w[overview info logs].include?(state[:detailTab].to_s) ? state[:detailTab].to_s : "overview"
        {
          open: !!state[:open],
          selectedUnit: state[:selectedUnit].to_s,
          filter: filter,
          query: state[:query].to_s,
          detailTab: tab,
          requestedAt: state[:requestedAt].to_s
        }
      end

      def normalize_log_state(log_state)
        state = default_log_state.merge((log_state || {}).transform_keys(&:to_sym))
        status = %w[idle loading ready error].include?(state[:status].to_s) ? state[:status].to_s : "idle"
        {
          unit: state[:unit].to_s,
          status: status,
          lines: Array(state[:lines]).map(&:to_s),
          error: state[:error].to_s,
          updatedAt: state[:updatedAt].to_s
        }
      end

      def with_scan_lock(config)
        ensure_state_dir(config)
        File.open(lock_path(config, SCAN_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      def acquire_daemon_lock(config)
        ensure_state_dir(config)
        file = File.open(lock_path(config, DAEMON_LOCK_FILE), File::RDWR | File::CREAT, 0o600)
        return nil unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.rewind
        file.write("#{::Process.pid}\n")
        file.flush
        file
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        nil
      end

      def daemon_pid(config)
        path = lock_path(config, DAEMON_LOCK_FILE)
        return nil unless File.file?(path)

        pid = File.read(path).to_i
        pid.positive? ? pid : nil
      rescue StandardError
        nil
      end

      def ensure_ui_state(config)
        ensure_state_dir(config)
        ensure_state_event(config)
        write_ui_state(config, default_ui_state) unless File.file?(ui_state_path(config))
        write_log_state(config, default_log_state) unless File.file?(log_state_path(config))
      end

      def ensure_state_dir(config)
        FileUtils.mkdir_p(state_dir(config))
      end

      def ensure_state_event(config)
        notify_state_change(config) unless File.file?(state_event_path(config))
      end

      def notify_state_change(config)
        ensure_state_dir(config)
        write_watched_json(state_event_path(config), updatedAt: Time.now.utc.iso8601(6))
      end

      def atomic_write_json(path, payload)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"
        # binwrite: JSON is UTF-8 and the bytes must not be transcoded through
        # the process's external encoding (a C locale would raise on any
        # non-ASCII byte in the payload).
        File.binwrite(temp_path, "#{JSON.pretty_generate(payload)}\n".encode(Encoding::UTF_8))
        File.chmod(0o600, temp_path)
        File.rename(temp_path, path)
        File.chmod(0o600, path)
        path
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      # The one file QuickShell watches with inotify. Renaming over it would
      # drop the watch, so it is truncated and rewritten in place.
      def write_watched_json(path, payload)
        contents = "#{JSON.generate(payload)}\n".encode(Encoding::UTF_8)
        File.open(path, File::RDWR | File::CREAT | File::BINARY, 0o600) do |file|
          file.rewind
          file.write(contents)
          file.truncate(file.pos)
          file.flush
          file.fsync
        end
        File.chmod(0o600, path)
        path
      end

      def lock_path(config, name)
        File.join(state_dir(config), name)
      end
    end
  end
end
