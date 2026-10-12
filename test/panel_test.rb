# frozen_string_literal: true

require_relative "test_helper"

# Structural contract for the QuickShell panel.
#
# qmllint cannot validate this file in CI (the Quickshell ShellRoot type only
# exists where Quickshell is installed), so the panel's load-bearing shape is
# asserted here instead of being left to a gate that can only fail.
class PanelTest < Minitest::Test
  PANEL = File.expand_path("../frontend/quickshell/shell.qml", __dir__)

  def panel_source
    @panel_source ||= File.read(PANEL)
  end

  def test_panel_exists
    assert File.file?(PANEL), "frontend/quickshell/shell.qml is the only human UI"
  end

  def test_panel_is_a_shellroot_with_a_panelwindow
    assert_includes panel_source, "ShellRoot {"
    assert_includes panel_source, "PanelWindow {"
  end

  # The panel is a cached-state renderer: it reads state files and dispatches
  # CLI commands, and must never run systemd itself. (Naming systemctl in a
  # tooltip is fine; invoking it is not.)
  def test_panel_never_invokes_systemctl_journalctl_or_the_daemon_socket
    refute_match(/Process\s*\{[^}]*systemctl/m, panel_source)
    refute_match(/command:\s*\[[^\]]*systemctl/, panel_source)
    refute_match(/daemon\.sock/, panel_source)
    refute_match(/command:\s*\[[^\]]*journalctl/, panel_source)
  end

  def test_panel_watches_the_snapshot_ui_log_and_event_files
    %w[snapshot.json ui.json log.json state-event.json].each do |file|
      assert_includes panel_source, file
    end
  end

  # Everything the presenter emits and the panel renders by name.
  def test_panel_reads_the_presenter_contract
    %w[status kind port probeUp sinceBoot uptimeText restarts memoryText appRoot
       signals fragmentPath probeStatus probeConnectMs].each do |field|
      assert_includes panel_source, field, "panel does not render #{field}"
    end
  end

  # Every mutation is one of the CLI commands the daemon actually handles.
  def test_panel_dispatches_only_real_cli_commands
    commands = panel_source.scan(/runSwitchyard\(\["([a-z-]+)"/).flatten.uniq.sort
    allowed = %w[open refresh ui start stop restart reload enable disable reset-failed logs]

    assert_equal [], commands - allowed, "panel dispatches an unknown command"
    assert_includes commands, "ui"
  end

  def test_panel_wires_the_omarchy_theme_palette
    assert_includes panel_source, "OMARCHY_THEME_COLORS"
    assert_includes panel_source, "themeColor("
  end

  # A Repeater delegate must be an Item; Shortcut is a QtObject.
  def test_shortcuts_are_not_in_a_repeater
    assert_includes panel_source, "Shortcut {"
    refute_match(/Repeater\s*\{[^}]*Shortcut/, panel_source)
  end

  def test_panel_is_a_bar_positioned_compact_popover
    assert_includes panel_source, "property int popupTopMargin: 52"
    assert_match(/id: modalFrame\s+anchors\.horizontalCenter: parent\.horizontalCenter\s+anchors\.top: parent\.top\s+anchors\.topMargin: root\.popupTopMargin/m, panel_source)
    assert_includes panel_source, "width: Math.min(480, Math.max(1, panel.width - 24))"
    refute_includes panel_source, "width: Math.min(1180"
    refute_includes panel_source, "mask: Region { item: modalFrame"
  end

  def test_clicking_outside_the_popover_dismisses_it_without_a_scrim
    assert_match(/MouseArea\s*\{\s*anchors\.fill: parent\s*onClicked: root\.closePanel\(\)/m, panel_source)
    assert_includes panel_source, "color: \"transparent\""
  end

  def test_compact_popover_stacks_unit_list_and_details
    assert_includes panel_source, 'text: "Rails · " + root.summaryLine()'
    assert_includes panel_source, "Layout.preferredHeight: Math.min(180, Math.max(58, root.filteredUnits().length * 60))"
    assert_includes panel_source, "Layout.preferredHeight: 220"
  end
end
