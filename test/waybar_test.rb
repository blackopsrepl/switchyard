# frozen_string_literal: true

require_relative "test_helper"

class WaybarTest < Minitest::Test
  def test_payload_without_a_snapshot_is_loading
    payload = Switchyard::Runtime::Waybar.payload(build_config, nil)

    assert_equal "...", payload[:text]
    assert_includes payload[:class], "loading"
    assert_includes payload[:tooltip], "Switchyard"
  end

  def test_payload_renders_the_cached_chip
    rows = [{
      unit: "app.service", kind: "rails", activeState: "active", subState: "running",
      unitFileState: "enabled", restarts: 0, port: 3000, probe: { ok: true, status: 200 }
    }]
    view = Switchyard::Runtime::Presenter.build_view(build_config, rows)
    payload = Switchyard::Runtime::Waybar.payload(build_config, { view: view })

    assert_equal "1/1 up", payload[:text]
    assert_includes payload[:class], "healthy"
  end
end
