# frozen_string_literal: true

require_relative "test_helper"

class QuickShellTest < Minitest::Test
  def test_status_reports_the_state_paths
    path = write_test_config
    status = Switchyard::Runtime::QuickShell.status(path)

    assert status.key?(:ui)
    assert status[:snapshotPath].end_with?("snapshot.json")
    assert status[:uiPath].end_with?("ui.json")
    assert status[:logPath].end_with?("log.json")
    assert status[:stateEventPath].end_with?("state-event.json")
  end

  def test_status_reports_not_running_when_no_shell_matches
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    # No QuickShell is running against this temporary install path.
    refute Switchyard::Runtime::QuickShell.running?(config)
  end

  def test_executable_prefers_the_checkout_bin
    assert_equal File.expand_path("../bin/switchyard", __dir__), Switchyard::Runtime::QuickShell.executable
  end

  # The panel must come up on Wayland. Without QT_QPA_PLATFORM a launcher with no
  # session environment (a keybind from a service, a cron job) loads QuickShell
  # against the wrong platform backend and the panel never appears.
  def test_ensure_running_sets_the_wayland_platform_and_install_paths
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)
    captured = nil

    Switchyard::Core::Process.stub(:spawn_detached, ->(command, args, env: {}, cwd: nil) { captured = [command, args, env, cwd] }) do
      Switchyard::Runtime::QuickShell.stub(:running?, false) do
        Switchyard::Runtime::QuickShell.ensure_running(config, path)
      end
    end

    refute_nil captured, "ensure_running did not spawn QuickShell"
    _command, args, env, cwd = captured

    assert_equal "wayland", env["QT_QPA_PLATFORM"]
    assert_equal File.expand_path(path), env["SWITCHYARD_CONFIG"]
    assert_equal Switchyard::Runtime::State.state_dir(config), env["SWITCHYARD_STATE_DIR"]
    assert_equal Switchyard::Runtime::QuickShell.executable, env["SWITCHYARD_BIN"]
    assert_includes args, "--daemonize"
    assert_includes args, "--no-duplicate"
    assert_equal File.dirname(config.dig(:runtime, :quickShellShell)), cwd
  end
end
