# frozen_string_literal: true

require "fileutils"
require "json"

module Switchyard
  module Core
    module Config
      CONFIG_VERSION = 1

      # Every candidate unit on this host is a system service; nothing here is
      # scoped to a user manager.
      DEFAULT_SERVICE_PATTERNS = ["*.service"].freeze

      # Units that match the Rails markers purely by accident (or that are
      # infrastructure rather than a development environment) are excluded
      # before detection runs. Patterns are File.fnmatch globs.
      DEFAULT_EXCLUDE_UNITS = [
        "systemd-*",
        "dracut-*",
        "getty@*",
        "user@*",
        "serial-getty@*",
        "podman-*",
        "*.mount",
        "*.swap"
      ].freeze

      DEFAULT_ENV_MARKERS = %w[RAILS_ENV RACK_ENV BUNDLE_GEMFILE BUNDLE_PATH RAILS_MAX_THREADS].freeze

      # What kind of environment a unit is, by the client it runs. These two
      # lists are the classification vocabulary; the detection marker list below
      # is derived from them, so a client can never be classifiable but
      # undetectable (a site server silently missing from the dashboard).
      SITE_EXEC_MARKERS = ["bridgetown", "hugo", "jekyll"].freeze
      WORKER_EXEC_MARKERS = ["sidekiq", "good_job", "solid_queue", "delayed_job", "resque", "shoryuken"].freeze

      # Substrings looked for in ExecStart. `bundle` alone would be too broad
      # (any Ruby tool), so the server client names are what make it a
      # development environment. Every classification marker is included by
      # construction; "rails", "puma" and "rackup" are the ones that carry no
      # separate kind because "rails" is the default.
      DEFAULT_EXEC_MARKERS = (["rails", "puma", "rackup"] + SITE_EXEC_MARKERS + WORKER_EXEC_MARKERS).uniq.freeze

      # A working directory under one of these roots is what makes a unit a
      # development environment rather than a system daemon that happens to run
      # Ruby. `rails new` writes config/application.rb at the root.
      DEFAULT_WORKDIR_MARKERS = [
        File.join(Dir.home, "hack"),
        "/srv/lab/dev",
        "/srv/lab/hack",
        "/srv/lab/sites"
      ].freeze

      module_function

      def default_config
        {
          version: CONFIG_VERSION,
          servicePatterns: DEFAULT_SERVICE_PATTERNS.dup,
          excludeUnits: DEFAULT_EXCLUDE_UNITS.dup,
          envMarkers: DEFAULT_ENV_MARKERS.dup,
          execMarkers: DEFAULT_EXEC_MARKERS.dup,
          workdirMarkers: DEFAULT_WORKDIR_MARKERS.dup,
          # Explicit kind overrides win over detection, keyed by unit name.
          kinds: {},
          # Extra units to watch even when detection would skip them.
          pinnedUnits: [],
          # `sudo -n` keeps privilege escalation non-interactive: a dashboard
          # must never block on a password prompt.
          systemctlPrefix: "sudo -n",
          systemctlBin: "systemctl",
          journalctlPrefix: "sudo -n",
          journalctlBin: "journalctl",
          probe: {
            enabled: true,
            timeoutMs: 500,
            hosts: ["127.0.0.1"]
          },
          logLines: 40,
          runtime: {
            refreshSeconds: 10,
            stateDir: File.join(Dir.home, ".local", "state", "switchyard"),
            waybarSignal: 11,
            quickShellCommand: "quickshell",
            quickShellShell: default_quickshell_shell,
            panelShortcut: "Super+Shift+Y"
          }
        }
      end

      def default_quickshell_shell
        File.expand_path("../../../frontend/quickshell/shell.qml", __dir__)
      end

      def default_config_path
        File.join(Dir.home, ".switchyard", "config.json")
      end

      def load_config(config_path = default_config_path)
        normalize_config(read_json_file(config_path) || {})
      end

      # Explicit UTF-8: under a C/POSIX locale (a systemd --user daemon, a cron
      # job) Ruby tags File.read content US-ASCII and JSON's parser then raises
      # InvalidByteSequenceError on the first non-ASCII byte.
      def read_json_file(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: Encoding::UTF_8), symbolize_names: true)
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      def save_config(config, config_path = default_config_path)
        normalized = normalize_config(config)
        FileUtils.mkdir_p(File.dirname(File.expand_path(config_path)))
        # binwrite: the JSON is UTF-8 bytes and must land verbatim under any
        # locale, never transcoded to the process's external encoding.
        File.binwrite(config_path, "#{JSON.pretty_generate(normalized)}\n".encode(Encoding::UTF_8))
        File.chmod(0o600, config_path)
        normalized
      end

      def init_config(config_path = default_config_path)
        save_config(default_config, config_path)
      end

      def normalize_config(input)
        input ||= {}
        {
          version: CONFIG_VERSION,
          servicePatterns: string_list(input[:servicePatterns], DEFAULT_SERVICE_PATTERNS),
          excludeUnits: string_list(input[:excludeUnits], DEFAULT_EXCLUDE_UNITS),
          envMarkers: string_list(input[:envMarkers], DEFAULT_ENV_MARKERS),
          execMarkers: string_list(input[:execMarkers], DEFAULT_EXEC_MARKERS),
          workdirMarkers: string_list(input[:workdirMarkers], DEFAULT_WORKDIR_MARKERS),
          kinds: normalize_kinds(input[:kinds]),
          pinnedUnits: string_list(input[:pinnedUnits], []),
          systemctlPrefix: input[:systemctlPrefix].to_s,
          systemctlBin: clean(input[:systemctlBin]) || "systemctl",
          journalctlPrefix: input[:journalctlPrefix].to_s,
          journalctlBin: clean(input[:journalctlBin]) || "journalctl",
          probe: normalize_probe(input[:probe]),
          logLines: [[positive_int((input[:logLines] || 40), 40), 5].max, 2000].min,
          runtime: normalize_runtime(input[:runtime])
        }
      end

      def normalize_kinds(input)
        (input || {}).each_with_object({}) do |(unit, kind), acc|
          text = clean(kind)
          next unless text

          acc[unit.to_s] = text
        end
      end

      def normalize_probe(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          enabled: boolean(input[:enabled], true),
          timeoutMs: [[positive_int(input[:timeoutMs], 500), 100].max, 5000].min,
          hosts: string_list(input[:hosts], ["127.0.0.1"])
        }
      end

      def normalize_runtime(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          refreshSeconds: [positive_int(input[:refreshSeconds], 10), 2].max,
          stateDir: File.expand_path(clean(input[:stateDir]) || File.join(Dir.home, ".local", "state", "switchyard")),
          waybarSignal: positive_int(input[:waybarSignal], 11),
          quickShellCommand: clean(input[:quickShellCommand]) || "quickshell",
          quickShellShell: File.expand_path(clean(input[:quickShellShell]) || default_quickshell_shell),
          panelShortcut: clean(input[:panelShortcut]) || "Super+Shift+Y"
        }
      end

      def validate_config(config, config_path: nil)
        issues = []
        if config_path && !File.file?(config_path)
          issues << issue("warning", "configPath", "No config file at #{config_path}; defaults are in use. Run 'switchyard config init' to make it editable.")
        end
        issues << issue("error", "version", "Expected #{CONFIG_VERSION}.") unless config[:version] == CONFIG_VERSION
        if Array(config[:servicePatterns]).empty?
          issues << issue("error", "servicePatterns", "At least one unit glob is required.")
        end
        shell = config.dig(:runtime, :quickShellShell).to_s
        issues << issue("warning", "runtime.quickShellShell", "QuickShell shell not found at #{shell}.") unless File.file?(shell)
        %i[systemctlBin journalctlBin].each do |key|
          bin = config[key].to_s
          issues << issue("warning", key.to_s, "#{bin} is not executable.") unless executable_or_bare?(bin)
        end
        Array(config[:workdirMarkers]).each do |root|
          issues << issue("warning", "workdirMarkers", "Root not found: #{root}.") unless Dir.exist?(root)
        end
        missing = Core::Detect.unreachable_kind_markers(config)
        unless missing.empty?
          issues << issue("error", "execMarkers",
                          "Kind markers unreachable by detection: #{missing.join(', ')}. Add them to execMarkers or remove them from the kind lists.")
        end
        issues
      end

      def executable_or_bare?(name)
        name.include?("/") ? File.executable?(name) : true
      end

      def string_list(input, default)
        values = Array(input).map { |value| value.to_s.strip }.reject(&:empty?)
        values.empty? ? default.dup : values
      end

      def positive_int(value, default)
        parsed = value.is_a?(Numeric) ? value.to_i : value.to_s.to_i
        parsed.positive? ? parsed : default
      end

      def boolean(value, default)
        return default if value.nil?

        [true, 1, "1", "true", "yes", "on"].include?(value)
      end

      def clean(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def issue(severity, field, message)
        { severity: severity, field: field, message: message }
      end
    end
  end
end
