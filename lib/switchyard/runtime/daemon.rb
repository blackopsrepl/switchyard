# frozen_string_literal: true

require "json"
require "fileutils"
require "socket"
require "time"

module Switchyard
  module Runtime
    # The resident action daemon. It owns the scan timer, every mutation, the
    # log fetch, and the unix socket the CLI and the panel dispatch through.
    module Daemon
      module_function

      # Non-ASCII in the chip tooltip and the alerts is deliberate (the dot
      # separator), so the locale is pinned rather than the text downgraded.
      # A daemon under systemd --user inherits no locale at all.
      def set_locale_encoding
        Encoding.default_external = Encoding::UTF_8
        Encoding.default_internal = nil
        nil
      end

      def run(config_path, once: false)
        set_locale_encoding
        config = Core::Config.load_config(config_path)
        return Store.scan_effect(config_path) if once

        lock = State.acquire_daemon_lock(config)
        raise "switchyard daemon already running for #{State.state_dir(config)}." unless lock

        State.ensure_ui_state(config)
        run_action_server(config_path, config)
      ensure
        lock&.close
      end

      def scan(config_path, config: nil)
        config ||= Core::Config.load_config(config_path)
        Store.scan_effect(config_path)
      end

      def dispatch_action(config_path, action)
        config = Core::Config.load_config(config_path)
        ensure_running(config_path, config)
        socket_path = State.daemon_socket_path(config)
        UNIXSocket.open(socket_path) do |socket|
          socket.write("#{JSON.generate(action)}\n")
          socket.flush
          response = socket.gets
          raise "switchyard daemon closed the action socket." unless response

          payload = JSON.parse(response, symbolize_names: true)
          raise payload[:error].to_s unless payload[:ok]

          payload[:result]
        end
      end

      def ensure_running(config_path, config = nil)
        config ||= Core::Config.load_config(config_path)
        return if socket_ready?(config)

        stop_socketless_daemon(config)
        executable = executable_path
        Core::Process.spawn_detached(executable, ["daemon", "--config", File.expand_path(config_path)])
        deadline = Time.now + 3
        sleep 0.05 until socket_ready?(config) || Time.now >= deadline
        raise "switchyard daemon did not start for #{State.state_dir(config)}." unless socket_ready?(config)
      end

      def stop_socketless_daemon(config)
        pid = State.daemon_pid(config)
        return unless pid
        return unless Core::Process.alive?(pid)

        result = Core::Process.run("ps", ["-p", pid.to_s, "-o", "args="])
        return unless result.success? && result.stdout.include?("switchyard") && result.stdout.include?("daemon")

        ::Process.kill("TERM", pid)
        deadline = Time.now + 1
        sleep 0.05 while Core::Process.alive?(pid) && Time.now < deadline
      rescue StandardError
        nil
      end

      def run_action_server(config_path, initial_config)
        socket_path = State.daemon_socket_path(initial_config)
        FileUtils.rm_f(socket_path)
        server = UNIXServer.new(socket_path)
        File.chmod(0o600, socket_path)
        next_scan_at = Time.now
        scan_state = { thread: nil, pending: false, mutex: Mutex.new }
        log_threads = []
        mutex = Mutex.new

        loop do
          config = Core::Config.load_config(config_path)
          if Time.now >= next_scan_at
            request_scan(config_path, scan_state, queue_pending: false)
            next_scan_at = Time.now + config.dig(:runtime, :refreshSeconds).to_i
          end

          ready = IO.select([server], nil, nil, 0.25)
          next unless ready

          client = server.accept
          request = client.gets
          result = handle_action(config_path, JSON.parse(request.to_s, symbolize_names: true), mutex, log_threads, scan_state)
          client.write("#{JSON.generate(ok: true, result: result)}\n")
        rescue StandardError => e
          client&.write("#{JSON.generate(ok: false, error: e.message)}\n")
          warn "switchyard daemon action error: #{e.message}"
        ensure
          client&.close
          log_threads.reject! { |thread| !thread.alive? }
        end
      ensure
        server&.close
        FileUtils.rm_f(socket_path) if socket_path
      end

      def handle_action(config_path, action, mutex, log_threads, scan_state)
        type = action[:type].to_s
        result = nil
        scan_needed = false
        log_job = nil

        mutex.synchronize do
          case type
          when "open_panel"
            result = Store.open_panel(config_path, action[:unit])
          when "close_panel"
            result = Store.close_panel(config_path)
          when "select_unit"
            result = Store.select_unit(config_path, action[:unit].to_s)
          when "filter"
            result = Store.set_filter(config_path, action[:filter].to_s)
          when "filter_query"
            result = Store.set_query(config_path, action[:query].to_s)
          when "detail_tab"
            result = Store.set_detail_tab(config_path, action[:tab].to_s)
          when "start", "stop", "restart", "reload"
            result = Store.control_unit(config_path, type, action[:unit].to_s)
            scan_needed = result[:ok]
          when "toggle_enabled"
            result = Store.toggle_enabled(config_path, action[:unit].to_s)
            scan_needed = result[:ok]
          when "enable", "disable"
            result = Store.set_enabled(config_path, action[:unit].to_s, enabled: type == "enable")
            scan_needed = result[:ok]
          when "reset_failed"
            result = Store.reset_failed(config_path, action[:unit].to_s)
            scan_needed = result[:ok]
          when "refresh"
            result = { status: "scan_requested" }
            scan_needed = true
          when "logs"
            unit = action[:unit].to_s
            log_job = unit
            result = { unit: unit, status: "loading" }
          when "ping"
            result = { status: "ok" }
          else
            raise ArgumentError, "Unknown daemon action: #{type}"
          end
        end

        request_scan(config_path, scan_state) if scan_needed
        log_threads << start_log_thread(config_path, log_job) if log_job
        result
      end

      def request_scan(config_path, scan_state, queue_pending: true)
        scan_state[:mutex].synchronize do
          if scan_state[:thread]&.alive?
            scan_state[:pending] = true if queue_pending
            return scan_state[:thread]
          end

          scan_state[:pending] = false
          scan_state[:thread] = Thread.new { scan_loop(config_path, scan_state) }
        end
      end

      def scan_loop(config_path, scan_state)
        loop do
          scan(config_path)
          repeat = scan_state[:mutex].synchronize do
            if scan_state[:pending]
              scan_state[:pending] = false
              true
            else
              scan_state[:thread] = nil
              false
            end
          end
          break unless repeat
        end
      rescue StandardError => e
        scan_state[:mutex].synchronize do
          scan_state[:thread] = nil
          scan_state[:pending] = false
        end
        warn "switchyard daemon scan error: #{e.message}"
      end

      def start_log_thread(config_path, unit)
        Thread.new do
          Store.fetch_logs_effect(config_path, unit)
        rescue StandardError => e
          warn "switchyard daemon log error: #{e.message}"
        end
      end

      def socket_ready?(config)
        socket_path = State.daemon_socket_path(config)
        return false unless File.socket?(socket_path)

        UNIXSocket.open(socket_path) do |socket|
          socket.write("#{JSON.generate(type: 'ping')}\n")
          socket.flush
          response = socket.gets
          response && JSON.parse(response, symbolize_names: true)[:ok]
        end
      rescue StandardError
        false
      end

      def executable_path
        candidates = [
          File.expand_path("../../../bin/switchyard", __dir__),
          File.join(Dir.home, ".local", "bin", "switchyard")
        ]
        candidates.find { |candidate| File.executable?(candidate) } || "switchyard"
      end
    end
  end
end
