# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_default_config_marks_the_development_roots
    config = Switchyard::Core::Config.default_config

    assert_includes config[:workdirMarkers], "/srv/lab/dev"
    assert_includes config[:workdirMarkers], "/srv/lab/sites"
    assert_equal ["*.service"], config[:servicePatterns]
  end

  def test_privilege_prefix_keeps_the_dash_n_form
    config = Switchyard::Core::Config.default_config

    assert_equal "sudo -n", config[:systemctlPrefix]
    assert_equal "systemctl", config[:systemctlBin]
  end

  def test_empty_marker_list_falls_back_to_defaults
    config = Switchyard::Core::Config.normalize_config(workdirMarkers: [], execMarkers: [])

    refute_empty config[:workdirMarkers]
    refute_empty config[:execMarkers]
  end

  def test_unknown_kind_override_is_dropped
    config = Switchyard::Core::Config.normalize_config(kinds: { "a.service" => "rails", "b.service" => "" })

    assert_equal({ "a.service" => "rails" }, config[:kinds])
  end

  def test_refresh_seconds_never_go_below_two
    config = Switchyard::Core::Config.normalize_config(runtime: { refreshSeconds: 1 })

    assert_equal 2, config.dig(:runtime, :refreshSeconds)
  end

  def test_probe_timeout_is_clamped
    config = Switchyard::Core::Config.normalize_config(probe: { timeoutMs: 50 })

    assert_equal 100, config.dig(:probe, :timeoutMs)
  end

  def test_validate_reports_a_missing_quickshell_shell
    config = Switchyard::Core::Config.normalize_config(runtime: { quickShellShell: "/nonexistent/shell.qml" })
    issues = Switchyard::Core::Config.validate_config(config)

    assert(issues.any? { |issue| issue[:field] == "runtime.quickShellShell" })
  end

  # Validating a path that does not exist used to report "is valid": the load
  # silently fell back to defaults, so a stale or absent config read as fine.
  def test_validate_reports_a_missing_config_file
    config = Switchyard::Core::Config.default_config
    issues = Switchyard::Core::Config.validate_config(config, config_path: "/nonexistent/config.json")

    missing = issues.find { |issue| issue[:field] == "configPath" }
    refute_nil missing, "an absent config file was not reported"
    assert_includes missing[:message], "config init"
  end

  # A marker infer_kind can classify but detection can never reach is dead code:
  # the site server it names would be silently absent from the dashboard.
  def test_validate_flags_kind_markers_detection_cannot_reach
    config = Switchyard::Core::Config.normalize_config(execMarkers: ["rails"])
    issues = Switchyard::Core::Config.validate_config(config)

    unreachable = issues.find { |issue| issue[:field] == "execMarkers" }
    refute_nil unreachable, "unreachable kind markers were not reported"
    assert_equal "error", unreachable[:severity]
    assert_includes unreachable[:message], "hugo"
    assert_includes unreachable[:message], "sidekiq"
  end

  def test_default_markers_leave_no_kind_unreachable
    config = Switchyard::Core::Config.default_config

    assert_empty Switchyard::Core::Detect.unreachable_kind_markers(config)
  end

  def test_save_and_load_round_trip
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    assert_equal 1, config[:version]
    assert_equal File.join(File.dirname(path), "state"), config.dig(:runtime, :stateDir)
  end
end
