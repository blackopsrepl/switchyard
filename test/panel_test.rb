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

  def test_panel_is_a_bar_sized_drop_down_that_never_overlaps_the_screen
    assert_includes panel_source, "property int popupTopMargin: 52"
    assert_match(/id: modalFrame\s+anchors\.horizontalCenter: parent\.horizontalCenter\s+anchors\.top: parent\.top\s+anchors\.topMargin: root\.popupTopMargin/m, panel_source)
    assert_includes panel_source, "property int popupMaxWidth: 920"
    assert_includes panel_source, "property int popupMaxHeight: 760"
    # Content-fitted: the counted height takes the taller dashboard card and
    # caps at the space between the bar and the screen edge minus a gap —
    # never a fixed floor that floats the card away from its content, never
    # a height that overlaps the screen's bottom edge.
    assert_includes panel_source, "property int popupMinHeight: 480"
    assert_includes panel_source, "Math.min(root.filteredUnits().length, 12) * 60"
    assert_includes panel_source, "Math.min(96, root.alerts.length * 30)"
    assert_includes panel_source, "Math.max(listCardHeight, detailCardHeight)"
    assert_includes panel_source, "panel.height - root.popupTopMargin - 12"
    assert_includes panel_source, "ScrollBar.vertical: ScrollBar {"
    assert_includes panel_source, "policy: ScrollBar.AsNeeded"
    assert_includes panel_source, "width: Math.min(root.popupMaxWidth, Math.max(420, panel.width - 48))"
    assert_includes panel_source, "id: frameShadow"
    assert_includes panel_source, "id: dashboardColumns"
    assert_includes panel_source, "id: unitListCard"
    assert_includes panel_source, "id: detailCard"
    refute_includes panel_source, "Layout.preferredHeight: Math.min(180"
    refute_includes panel_source, "Layout.preferredHeight: 220"
    refute_includes panel_source, "mask: Region { item: modalFrame"
  end

  def test_panel_header_carries_the_live_dot_and_family_buttons
    assert_includes panel_source, "id: liveDot"
    assert_match(/id: liveDot.*?root\.pendingAction\.length > 0 \|\| actionRunner\.running \|\| uiActionRunner\.running/m, panel_source)
    assert_match(/ActionButton\s*\{\s*label: "Refresh"/m, panel_source)
    assert_match(/ActionButton\s*\{\s*label: "Close"/m, panel_source)
  end

  def test_clicking_outside_the_popover_dismisses_it_without_a_scrim
    assert_match(/MouseArea\s*\{\s*anchors\.fill: parent\s*onClicked: root\.closePanel\(\)/m, panel_source)
    assert_includes panel_source, "color: \"transparent\""
  end

  def test_service_kind_is_not_repeated_in_row_metadata
    assert_includes panel_source, 'Badge { label: unitRow.rowData ? unitRow.rowData.kind'
    refute_includes panel_source, 'parts.push(unit.appRoot ? "rails app"', "The service kind is repeated in the second row line"
  end

  def test_panel_keeps_service_list_and_details_side_by_side
    assert_includes panel_source, 'text: root.summaryLine()'
    assert_match(/Item\s*\{\s*id: dashboardColumns.*?id: wideDashboard.*?id: unitListCard.*?id: detailCard/m, panel_source)
    assert_includes panel_source, 'text: "Environments"'
    %w[STATE LISTENER HEALTH].each do |label|
      assert_includes panel_source, "label: \"#{label}\"", "Missing #{label} summary tile"
    end
    assert_operator panel_source.scan("Layout.fillHeight: true").length, :>=, 3
    refute_includes panel_source, "Layout.preferredHeight: Math.min(180"
    refute_includes panel_source, "Layout.preferredHeight: 220"
    %w[Start Restart Enable Reset\ failed Open Overview Unit Logs].each do |label|
      assert_includes panel_source, label
    end
  end

  def test_detail_selection_tracks_the_active_filter
    selected_entry = panel_source[/function selectedUnitEntry\(\).*?\n    \}/m]
    reconcile = panel_source[/function reconcileSelection\(\).*?\n    \}/m]

    assert_includes selected_entry, "root.filteredUnits()"
    assert_includes reconcile, "root.filteredUnits()"
    assert_includes reconcile, "root.selectUnit(units[0])"
  end

  def test_cli_actions_queue_without_cancelling_in_flight_commands
    assert_includes panel_source, "property var actionQueue: []"
    assert_includes panel_source, "property var uiActionQueue: []"
    assert_includes panel_source, "id: uiActionRunner"
    assert_includes panel_source, "function startNextAction()"
    assert_includes panel_source, "function startNextUiAction()"
    assert_includes panel_source, "root.actionQueue = queue.concat([nextAction])"
    assert_includes panel_source, "root.uiActionQueue = queue.concat([nextAction])"
    assert_includes panel_source, "root.startNextAction()"
    refute_includes panel_source, "actionRunner.signal(9)"
    assert_includes panel_source, 'root.runSwitchyard(["ui", "filter-query", text], "filter-query")'
    toggle_enabled = panel_source[/function toggleEnabled\(unit\).*?\n    \}/m]
    assert_includes toggle_enabled, "var target = unit.unit"
    assert_includes toggle_enabled, 'root.runSwitchyard([action, target], "", root.pendingAction)'
  end

  def test_reload_remains_available_for_the_selected_unit
    assert_match(/label: "Reload".*?root\.dispatchFor\("reload"/m, panel_source)
  end

  def test_narrow_panels_wrap_controls_and_keep_list_overflow_visible
    assert_match(/Flow\s*\{.*?id: unitFilterInput/m, panel_source)
    assert_match(/Flow\s*\{.*?label: "Reload"/m, panel_source)
    assert_includes panel_source, "function dashboardMinimumHeight()"
    assert_match(/id: unitList.*?ScrollBar\.vertical: ScrollBar \{ policy: ScrollBar\.AsNeeded \}/m, panel_source)
  end

  def test_narrow_viewports_show_full_width_list_or_details_without_squeezing_them_side_by_side
    assert_includes panel_source, "property bool narrowLayout: panel.width < 720"
    assert_includes panel_source, 'property bool shortViewport: panel.height < 560'
    assert_includes panel_source, 'property string narrowPanelView: "details"'
    assert_match(/id: wideUnitListCard.*?sourceComponent: unitListCardComponent.*?id: wideDetailCard.*?sourceComponent: detailCardComponent/m, panel_source)
    assert_match(/id: narrowPanelStack.*?id: narrowUnitListCard.*?sourceComponent: unitListCardComponent.*?id: narrowDetailCard.*?sourceComponent: detailCardComponent/m, panel_source)
    assert_includes panel_source, 'visible: !root.narrowLayout || root.narrowPanelView === "units" || !root.shortViewport'
    assert_includes panel_source, 'anchors.margins: root.shortViewport ? 8 : 12'
    assert_includes panel_source, 'spacing: root.shortViewport ? 6 : 10'
    assert_includes panel_source, 'label: "Environments"'
    assert_includes panel_source, 'label: "Selected service"'
    assert_includes panel_source, 'root.narrowPanelView = "details"'
    assert_includes panel_source, 'root.narrowPanelView = "units"'
    assert_includes panel_source, "function currentUnitList()"
  end

  def test_service_list_shows_a_scroll_cue_when_rows_overflow
    assert_includes panel_source, 'unitList.contentHeight > unitList.height ? " · scroll" : ""'
    assert_includes panel_source, "ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }"
  end
end
