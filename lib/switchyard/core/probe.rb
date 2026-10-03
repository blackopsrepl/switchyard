# frozen_string_literal: true

require "socket"
require "timeout"

module Switchyard
  module Core
    # An HTTP status probe against a discovered port.
    #
    # Deliberately not a health claim: a Rails app that answers 200 and one that
    # answers 500 are both "up", and both are reported as the status code that
    # came back. The only negative results are "no listener answered in time".
    module Probe
      module_function

      def probe(config, port, host: "127.0.0.1")
        return nil unless config.dig(:probe, :enabled)
        return nil if port.nil?

        timeout = config.dig(:probe, :timeoutMs).to_i / 1000.0
        return nil if timeout <= 0

        started = Time.now
        socket = nil
        Timeout.timeout(timeout + 0.2) do
          socket = TCPSocket.new(host, port)
        end
        elapsed = ((Time.now - started) * 1000).round
        { ok: true, status: http_status(host, port, timeout), connectMs: elapsed }
      rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
        nil
      ensure
        socket&.close
      end

      # A bare TCP connect is the real answer to "is anything there"; the HTTP
      # status is a bonus that must not be able to hang the scan.
      def http_status(host, port, timeout)
        socket = nil
        Timeout.timeout(timeout) do
          socket = TCPSocket.new(host, port)
          socket.write("GET / HTTP/1.0\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
          first = socket.gets
          return nil if first.nil?

          return first.split(/\s+/)[1].to_i
        end
      rescue Timeout::Error, StandardError
        nil
      ensure
        socket&.close
      end
    end
  end
end
