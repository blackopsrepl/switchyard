# frozen_string_literal: true

module Switchyard
  module Core
    # Parses the listening TCP sockets on the host with `ss -ltnpH`.
    #
    # `-p` only names processes this uid owns without elevation, which is every
    # Rails dev server on this host. Sockets with no owner still list their
    # address, so the port is reported with a pid of nil rather than dropped.
    module Ports
      HEADER = "LISTEN"

      module_function

      def scan
        result = Core::Process.run("ss", ["-ltnpH"])
        return {} unless result.success?

        parse(result.stdout)
      end

      def parse(text)
        text.to_s.each_line.each_with_object({}) do |line, acc|
          fields = line.split(/\s+/)
          next if fields.length < 4

          local = fields[3]
          address, port = split_local(local)
          next if port.nil?

          pid, command = parse_owner(fields[4..].to_a.join(" "))
          acc[port] = {
            port: port,
            address: address,
            host: host_of(address),
            pid: pid,
            command: command
          }
        end
      end

      def split_local(local)
        text = local.to_s
        if text.start_with?("[")
          address, port = text.match(/\A\[(.*)\]:(\d+)\z/)&.captures
          return [address, port&.to_i]
        end

        index = text.rindex(":")
        return [nil, nil] if index.nil?

        [text[0...index], text[(index + 1)..].to_i]
      end

      # users:(("ruby",pid=1550,fd=8))
      def parse_owner(text)
        match = text.to_s.match(/users:\(\(\(?"([^"]+)",pid=(\d+)/)
        return [nil, nil] if match.nil?

        [match[2].to_i, match[1]]
      end

      def host_of(address)
        case address
        when "127.0.0.1", "::1", "localhost" then "127.0.0.1"
        when "0.0.0.0", "*", "::" then "127.0.0.1"
        else address
        end
      end

      def wildcard?(address)
        ["0.0.0.0", "*", "::"].include?(address.to_s)
      end

      # Reads a unit's cgroup for the pids it owns. This is how a unit that was
      # started through `bundle exec rails server` — whose visible process is
      # `puma`, not the ExecStart path — is still matched to its port.
      # `unit` is a full unit name ("solverforge-site.service").
      def unit_pids(unit)
        name = unit.to_s
        return [] if name.empty?

        path = File.join("/sys/fs/cgroup/system.slice", name, "cgroup.procs")
        return [] unless File.readable?(path)

        File.read(path).split.map(&:to_i)
      rescue StandardError
        []
      end
    end
  end
end
