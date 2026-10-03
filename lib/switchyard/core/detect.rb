# frozen_string_literal: true

module Switchyard
  module Core
    # Decides whether a unit is a Rails development environment, and what kind
    # of environment it is.
    #
    # Markers are checked in cost order (no filesystem I/O first) and every
    # signal that fired is returned, so the panel can explain why a unit was
    # included instead of asking the operator to trust a boolean.
    module Detect
      KIND_RANK = {
        "rails" => 0,
        "site" => 1,
        "worker" => 2,
        "web" => 3,
        "ruby" => 4,
        "service" => 5
      }.freeze

      module_function

      # fields: the `systemctl show` field hash for one unit.
      # Returns nil when the unit is not a Rails environment.
      def classify(config, fields)
        unit = fields["Id"].to_s
        return nil if unit.empty?
        return nil if excluded?(config, unit)

        workdir = fields["WorkingDirectory"].to_s
        exec_text = fields["ExecStart"].to_s
        env = Core::Systemd.environment_hash(fields["Environment"])
        argv = Core::Systemd.exec_argv(exec_text)
        exec_path = Core::Systemd.exec_path(exec_text)

        signals = []
        signals << "RAILS_ENV" if env.key?("RAILS_ENV")
        signals << "RACK_ENV" if env.key?("RACK_ENV")
        signals << "BUNDLE_PATH" if env.key?("BUNDLE_PATH")
        signals << "BUNDLE_GEMFILE" if env.key?("BUNDLE_GEMFILE")

        combined = [exec_text, argv.join(" "), exec_path.to_s].join(" ").downcase
        Array(config[:execMarkers]).each do |marker|
          signals << "exec:#{marker}" if combined.include?(marker.downcase)
        end

        workdir_root = Array(config[:workdirMarkers]).find do |root|
          path = File.expand_path(workdir.to_s)
          path != "/" && path.start_with?(File.expand_path(root.to_s) + "/")
        end
        signals << "workdir:#{workdir_root}" if workdir_root

        app_root = rails_app_root(workdir)
        signals << "rails:config/application.rb" if app_root

        # A working directory under a development root is a weak signal on its
        # own: a game-server or container stack that lives in the same tree would
        # be swept in. Require a runtime marker (an environment variable, an
        # ExecStart client, or an actual Rails app root) before a unit counts.
        runtime_marker = signals.any? { |signal| signal.start_with?("RAILS_ENV", "RACK_ENV", "BUNDLE_", "exec:", "rails:") }
        override = config[:kinds].key?(unit) || Array(config[:pinnedUnits]).include?(unit)
        return nil unless runtime_marker || override

        kind = config[:kinds][unit] || infer_kind(exec_text, argv)
        {
          unit: unit,
          kind: kind,
          description: fields["Description"].to_s,
          workdir: workdir,
          appRoot: app_root,
          railsApp: !app_root.nil?,
          signals: signals.uniq,
          override: config[:kinds].key?(unit)
        }
      end

      def excluded?(config, unit)
        Array(config[:excludeUnits]).any? { |glob| File.fnmatch?(glob, unit) }
      end

      def rails_app_root(workdir)
        path = File.expand_path(workdir.to_s)
        return nil if path == "/" || path.empty?
        return nil unless File.file?(File.join(path, "config", "application.rb"))

        path
      end

      def infer_kind(exec_text, argv)
        text = [exec_text, argv.join(" ")].join(" ").downcase
        return "site" if Core::Config::SITE_EXEC_MARKERS.any? { |marker| text.include?(marker) }
        return "worker" if Core::Config::WORKER_EXEC_MARKERS.any? { |marker| text.include?(marker) }

        "rails"
      end

      # Every marker infer_kind can classify must also be a detection marker, or
      # the kind is unreachable.
      def unreachable_kind_markers(config)
        detectable = Array(config[:execMarkers]).map(&:downcase)
        (Core::Config::SITE_EXEC_MARKERS + Core::Config::WORKER_EXEC_MARKERS).reject { |marker| detectable.include?(marker.downcase) }
      end

      def rank(kind)
        KIND_RANK.fetch(kind.to_s, KIND_RANK.length)
      end

      def sort(environments)
        environments.sort_by { |env| [rank(env[:kind]), env[:unit]] }
      end
    end
  end
end
