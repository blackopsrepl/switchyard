# frozen_string_literal: true

require_relative "test_helper"

class PresenterTest < Minitest::Test
  def row(overrides = {})
    {
      unit: "app.service",
      kind: "rails",
      description: "App",
      activeState: "active",
      subState: "running",
      unitFileState: "enabled",
      loadState: "loaded",
      mainPid: 100,
      restarts: 0,
      user: "pvd",
      workdir: "/srv/lab/dev/app",
      appRoot: "/srv/lab/dev/app",
      railsApp: true,
      signals: ["RAILS_ENV"],
      override: false,
      memoryBytes: 2048,
      cpuSeconds: 1.5,
      startedAt: (Time.now - 3600).utc.iso8601,
      fragmentPath: "/etc/systemd/system/app.service",
      port: nil,
      portAddress: nil,
      portCommand: nil,
      portPids: [],
      probe: nil
    }.merge(overrides)
  end

  # A unit that is enabled and keeps exiting reads as "activating/auto-restart",
  # which is the one status that matters most and the one systemd does not label.
  def test_enabled_auto_restart_is_a_crash_loop
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(activeState: "activating", subState: "auto-restart", restarts: 2402))

    assert_equal "crash-loop", view[:status]
    assert_equal "bad", view[:tone]
  end

  def test_failed_but_disabled_is_a_plain_failure
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(activeState: "failed", subState: "failed", unitFileState: "disabled"))

    assert_equal "failed", view[:status]
  end

  def test_inactive_dead_is_stopped
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(activeState: "inactive", subState: "dead"))

    assert_equal "stopped", view[:status]
  end

  def test_active_is_running
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row)

    assert_equal "running", view[:status]
    assert_equal "good", view[:tone]
  end

  def test_summary_counts_states_and_restarts
    config = build_config
    rows = [
      row(unit: "a.service"),
      row(unit: "b.service", activeState: "inactive", subState: "dead"),
      row(unit: "c.service", activeState: "activating", subState: "auto-restart", restarts: 12, port: 3000, probe: { ok: true, status: 200, connectMs: 1 })
    ]

    view = Switchyard::Runtime::Presenter.build_view(config, rows)

    assert_equal 3, view[:summary][:total]
    assert_equal 1, view[:summary][:running]
    assert_equal 1, view[:summary][:stopped]
    assert_equal 1, view[:summary][:failing]
    assert_equal 12, view[:summary][:restarts]
    assert_equal 1, view[:summary][:ports]
    assert_equal 1, view[:summary][:probes]
  end

  def test_alerts_name_the_crash_loop_and_its_restart_count
    rows = [row(unit: "bad.service", activeState: "activating", subState: "auto-restart", restarts: 7, startedAt: (Time.now - 5).utc.iso8601)]

    view = Switchyard::Runtime::Presenter.build_view(build_config, rows)

    assert_equal 1, view[:alerts].length
    assert_includes view[:alerts].first, "bad.service"
    assert_includes view[:alerts].first, "7 restarts"
  end

  def test_chip_reports_failures_and_sets_classes
    rows = [row(unit: "ok.service"), row(unit: "bad.service", activeState: "activating", subState: "auto-restart", restarts: 3)]
    view = Switchyard::Runtime::Presenter.build_view(build_config, rows)

    assert_equal "1/2 1 failing", view[:chip][:text]
    assert_includes view[:chip][:classes], "has-failures"
    assert_includes view[:chip][:classes], "has-restarts"
  end

  def test_chip_without_units_is_loading
    view = Switchyard::Runtime::Presenter.build_view(build_config, [])

    assert_equal "...", view[:chip][:text]
    assert_includes view[:chip][:classes], "loading"
  end

  # "Restarts 2402 · up 3h" is contradictory unless the panel says the current
  # run started at boot.
  def test_since_boot_marks_a_unit_started_by_the_boot
    now = Time.now
    booted_at = now - Switchyard::Runtime::Presenter.host_uptime_seconds
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(startedAt: (booted_at + 5).utc.iso8601))

    assert view[:sinceBoot]
  end

  def test_since_boot_is_false_for_an_explicit_start
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(startedAt: (Time.now - 5).utc.iso8601))

    refute view[:sinceBoot]
    assert_equal "running", view[:status]
  end

  def test_memory_and_probe_are_shaped_for_display
    view = Switchyard::Runtime::Presenter.unit_view(build_config, row(memoryBytes: 5 * 1024 * 1024, port: 3000, probe: { ok: true, status: 200, connectMs: 3 }))

    assert_equal "5.0 MiB", view[:memoryText]
    assert view[:probeUp]
    assert_equal 200, view[:probeStatus]
    assert_equal "http://127.0.0.1:3000/", view[:url]
  end
end
