# frozen_string_literal: true

require "json"

module Switchyard
  module Runtime
    # The Waybar chip. A cached-state renderer only: it never scans systemd, it
    # prints what the last snapshot said and asks the daemon to refresh.
    module Waybar
      module_function

      def render(config_path, out: $stdout)
        config = Core::Config.load_config(config_path)
        snapshot = State.read_snapshot(config)
        out.puts(JSON.generate(payload(config, snapshot)))
      end

      def payload(config, snapshot, now = Time.now)
        if snapshot.nil?
          return {
            text: "...",
            tooltip: "Switchyard is waiting for its first scan.\nLeft click: open the panel  ·  Middle click: refresh",
            class: %w[switchyard loading]
          }
        end

        view = snapshot[:view] || Presenter.build_view(config, snapshot[:units] || [], now)
        chip = view[:chip] || {}
        {
          text: chip[:text] || "...",
          tooltip: Array(chip[:tooltipLines]).join("\n"),
          class: Array(chip[:classes]).uniq
        }
      end
    end
  end
end
