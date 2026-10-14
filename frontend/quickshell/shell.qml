import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property string configPath: Quickshell.env("SWITCHYARD_CONFIG") || ((Quickshell.env("HOME") || "") + "/.switchyard/config.json")
    property string stateDir: Quickshell.env("SWITCHYARD_STATE_DIR") || ((Quickshell.env("HOME") || "") + "/.local/state/switchyard")
    property string switchyardBin: Quickshell.env("SWITCHYARD_BIN") || "switchyard"
    property string snapshotPath: stateDir + "/snapshot.json"
    property string uiPath: stateDir + "/ui.json"
    property string logPath: stateDir + "/log.json"
    property string stateEventPath: stateDir + "/state-event.json"
    property string textFont: "Fira Code"

    // Omarchy theme wiring: follows the active Omarchy palette the same way the
    // rest of the bar family does, and falls back to the built-in palette where
    // a key is absent or Omarchy is not running.
    property string themeColorsPath: Quickshell.env("OMARCHY_THEME_COLORS") || ((Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml")
    property var themePalette: ({})

    function applyThemeColors(raw) {
        var parsed = {}
        var lines = String(raw || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match)
                parsed[match[1]] = match[2]
        }
        root.themePalette = parsed
    }

    function themeColor(key, fallback) {
        var value = root.themePalette[key]
        return (typeof value === "string" && value.length > 0) ? value : fallback
    }

    readonly property QtObject theme: QtObject {
        readonly property color bg: root.themeColor("background", "#0B0C16")
        readonly property color surfaceDeep: root.themeColor("selection", "#0F1324")
        readonly property color surfaceAlt: root.themeColor("lighter_background", "#141528")
        readonly property color surfaceHover: root.themeColor("selection", "#18233C")
        readonly property color surfaceSelect: root.themeColor("muted", "#202848")
        readonly property color surfaceDown: root.themeColor("muted", "#223354")
        readonly property color border: root.themeColor("muted", "#253057")
        readonly property color borderStrong: root.themeColor("dark_foreground", "#4A557C")
        readonly property color text: root.themeColor("bright_foreground", "#DDF7FF")
        readonly property color textMuted: root.themeColor("dark_foreground", "#6A6E95")
        readonly property color good: root.themeColor("green", "#82FB9C")
        readonly property color goodSoft: root.themeColor("bright_green", "#9CF7C2")
        readonly property color info: root.themeColor("bright_cyan", "#85E1FB")
        readonly property color accent: root.themeColor("accent", "#8FA4D8")
        readonly property color warn: root.themeColor("yellow", "#F2C572")
        readonly property color bad: root.themeColor("red", "#E06C75")
        readonly property color infoFill: Qt.rgba(root.theme.info.r, root.theme.info.g, root.theme.info.b, 0.16)
        readonly property color goodFill: Qt.rgba(root.theme.goodSoft.r, root.theme.goodSoft.g, root.theme.goodSoft.b, 0.16)
        readonly property color warnFill: Qt.rgba(root.theme.warn.r, root.theme.warn.g, root.theme.warn.b, 0.16)
        readonly property color badFill: Qt.rgba(root.theme.bad.r, root.theme.bad.g, root.theme.bad.b, 0.16)
    }

    FileView {
        id: themeFile
        path: root.themeColorsPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyThemeColors(text())
        onFileChanged: reload()
        onLoadFailed: root.applyThemeColors("")
    }

    property var viewData: snapshotAdapter.view ? snapshotAdapter.view : ({ summary: {}, units: [], alerts: [], chip: {} })
    property var units: viewData.units || []
    property var alerts: viewData.alerts || []
    property string pendingAction: ""
    property string actionError: ""
    property var actionQueue: []
    property var uiActionQueue: []
    property bool narrowLayout: panel.width < 720
    property bool shortViewport: panel.height < 560
    property string narrowPanelView: "details"

    // Waybar and QuickShell are separate processes, so the chip cannot provide
    // an anchor item. Keep a generous anchored-to-bar panel rather than
    // shrinking the service list and its operational details into a tiny card.
    property int popupTopMargin: 52
    property int popupMaxWidth: 920
    property int popupMaxHeight: 760
    property int popupMinHeight: 620

    function modalHeight() {
        // The list rows drive the panel's height; cap at the viewport so larger
        // installations scroll instead of growing over the whole desktop.
        var rowsHeight = 195 + root.filteredUnits().length * 60
        var alertsHeight = Math.min(96, root.alerts.length * 30)
        var desiredHeight = Math.max(root.popupMinHeight, rowsHeight + alertsHeight)
        var availableHeight = Math.max(1, panel.height - root.popupTopMargin - 24)
        return Math.min(root.popupMaxHeight, availableHeight, desiredHeight)
    }

    function dashboardMinimumHeight() {
        return Math.max(180, Math.min(360, root.modalHeight() - 260))
    }

    readonly property var filterOptions: [
        { key: "all", label: "All" },
        { key: "running", label: "Running" },
        { key: "stopped", label: "Stopped" },
        { key: "failed", label: "Failing" }
    ]

    function statusTone(status) {
        if (status === "running") { return "good" }
        if (status === "reloading") { return "info" }
        if (status === "crash-loop" || status === "failed") { return "bad" }
        if (status === "unknown") { return "warn" }
        return "muted"
    }

    function toneColor(tone) {
        if (tone === "bad") { return root.theme.bad }
        if (tone === "warn") { return root.theme.warn }
        if (tone === "info") { return root.theme.info }
        if (tone === "good") { return root.theme.goodSoft }
        return root.theme.textMuted
    }

    function matchesFilter(unit) {
        var filter = uiAdapter.filter
        if (filter === "running") { return unit.status === "running" || unit.status === "reloading" }
        if (filter === "stopped") { return unit.status === "stopped" }
        if (filter === "failed") { return unit.status === "crash-loop" || unit.status === "failed" }
        return true
    }

    function matchesQuery(unit) {
        var query = (uiAdapter.query || "").trim().toLowerCase()
        if (query.length === 0) { return true }
        var haystack = [unit.unit, unit.kind, unit.description, unit.appRoot, unit.workdir, unit.status,
            unit.port ? String(unit.port) : ""].join(" ").toLowerCase()
        return haystack.indexOf(query) >= 0
    }

    function filteredUnits() {
        var output = []
        for (var index = 0; index < root.units.length; index++) {
            var unit = root.units[index]
            if (root.matchesFilter(unit) && root.matchesQuery(unit)) {
                output.push(unit)
            }
        }
        return output
    }

    // The selection lives in ui.json (written by the daemon), not in view state,
    // so a row click, the keyboard and the CLI all agree on what is selected.
    function selectUnit(unit, revealDetails) {
        if (!unit) { return }
        root.actionError = ""
        if (root.narrowLayout && revealDetails)
            root.narrowPanelView = "details"
        root.runSwitchyard(["ui", "select", unit.unit], "selection")
    }

    function selectedUnitName() {
        return uiAdapter.selectedUnit || ""
    }

    function selectedUnitEntry() {
        var units = root.filteredUnits()
        for (var index = 0; index < units.length; index++) {
            if (units[index].unit === root.selectedUnitName()) {
                return units[index]
            }
        }
        return null
    }

    function selectedIndex() {
        var units = root.filteredUnits()
        for (var index = 0; index < units.length; index++) {
            if (units[index].unit === root.selectedUnitName()) {
                return index
            }
        }
        return -1
    }

    function currentUnitList() {
        var loader = root.narrowLayout ? narrowUnitListCard : wideUnitListCard
        return loader.item ? loader.item.listView : null
    }

    function moveSelection(delta) {
        var units = root.filteredUnits()
        if (units.length === 0) { return }
        var current = root.selectedIndex()
        if (current < 0) { current = 0 }
        var next = Math.max(0, Math.min(units.length - 1, current + delta))
        root.selectUnit(units[next], true)
        var list = root.currentUnitList()
        if (list) { list.positionViewAtIndex(next, ListView.Contain) }
    }

    // Auto-select the first unit whenever a selection stops making sense (fresh
    // state, a filter that hides the selection, a unit that disappeared).
    function reconcileSelection() {
        var units = root.filteredUnits()
        if (units.length === 0) { return }
        if (root.selectedUnitEntry() !== null) { return }
        root.selectUnit(units[0])
    }

    onUnitsChanged: selectionReconcile.restart()

    Timer {
        id: selectionReconcile
        interval: 60
        onTriggered: root.reconcileSelection()
    }

    Connections {
        target: uiAdapter
        function onFilterChanged() { selectionReconcile.restart() }
        function onQueryChanged() { selectionReconcile.restart() }
    }

    // Every mutation is a daemon action: the panel never runs systemctl itself.
    function runSwitchyard(args, coalesceKey, label) {
        var nextAction = {
            args: args,
            coalesceKey: coalesceKey || "",
            label: label || ""
        }
        var isUiAction = args.length > 0 && args[0] === "ui"
        var queue = isUiAction ? root.uiActionQueue : root.actionQueue
        if (nextAction.coalesceKey.length > 0) {
            var remaining = []
            for (var index = 0; index < queue.length; index++) {
                if (queue[index].coalesceKey !== nextAction.coalesceKey)
                    remaining.push(queue[index])
            }
            queue = remaining
        }
        if (isUiAction) {
            root.uiActionQueue = queue.concat([nextAction])
            if (!uiActionRunner.running)
                root.startNextUiAction()
            return
        }
        root.actionQueue = queue.concat([nextAction])
        if (nextAction.label.length > 0)
            root.pendingAction = nextAction.label
        if (!actionRunner.running)
            root.startNextAction()
    }

    function startNextAction() {
        if (actionRunner.running || root.actionQueue.length === 0) { return }
        var nextAction = root.actionQueue[0]
        root.actionQueue = root.actionQueue.slice(1)
        root.pendingAction = nextAction.label
        actionRunner.command = [root.switchyardBin].concat(nextAction.args).concat(["--config", root.configPath])
        actionRunner.running = true
    }

    function startNextUiAction() {
        if (uiActionRunner.running || root.uiActionQueue.length === 0) { return }
        var nextAction = root.uiActionQueue[0]
        root.uiActionQueue = root.uiActionQueue.slice(1)
        uiActionRunner.command = [root.switchyardBin].concat(nextAction.args).concat(["--config", root.configPath])
        uiActionRunner.running = true
    }

    function refresh() {
        root.pendingAction = "Scanning…"
        root.runSwitchyard(["refresh"], "refresh", "Scanning…")
    }

    function closePanel() {
        root.runSwitchyard(["ui", "close"])
    }

    function dispatchFor(action, unit) {
        if (!unit) { return }
        root.pendingAction = action + " " + unit
        root.actionError = ""
        root.runSwitchyard([action, unit], "", root.pendingAction)
    }

    function toggleEnabled(unit) {
        if (!unit) { return }
        var action = unit.enabled ? "disable" : "enable"
        var target = unit.unit
        root.pendingAction = action + " " + target
        root.actionError = ""
        root.runSwitchyard([action, target], "", root.pendingAction)
    }

    function openUnit(unit) {
        if (!unit || !unit.url) { return }
        root.runSwitchyard(["open", unit.url], "", "Opening " + unit.unit)
    }

    function reloadState() {
        snapshotFile.reload()
        uiFile.reload()
        logFile.reload()
    }

    function summaryLine() {
        var summary = viewData.summary || {}
        var parts = [(summary.running || 0) + "/" + (summary.total || 0) + " running"]
        if (summary.failing) { parts.push(summary.failing + " failing") }
        if (summary.ports) { parts.push(summary.ports + " listening") }
        if (summary.restarts) { parts.push(summary.restarts + " restarts") }
        return parts.join("  ·  ")
    }

    // Streamlined badge: tone carried by a left dot, not a filled pill, so a
    // row of them costs half the width while still reading at a glance. The
    // full label stays visible; nothing moved into a tooltip that the row
    // cannot already show.
    component Badge: Rectangle {
        id: badge

        property string label: ""
        property string tone: "muted"

        implicitWidth: badgeDot.implicitWidth + 4 + badgeText.implicitWidth + 8
        implicitHeight: 14
        radius: 3
        color: "transparent"

        Text {
            id: badgeDot
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: "●"
            color: root.toneColor(badge.tone)
            font.family: root.textFont
            font.pixelSize: 7
        }

        Text {
            id: badgeText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: badgeDot.right
            anchors.leftMargin: 4
            text: badge.label
            color: root.toneColor(badge.tone)
            font.family: root.textFont
            font.pixelSize: 8
        }
    }

    component ActionButton: Button {
        id: actionButton

        property string label: ""
        property string tooltip: ""
        property string tone: "info"
        property bool busy: false

        implicitWidth: actionLabel.implicitWidth + 22
        implicitHeight: 26
        padding: 0
        hoverEnabled: true
        enabled: !actionButton.busy

        ToolTip.delay: 350
        ToolTip.visible: actionButton.hovered && actionButton.tooltip.length > 0
        ToolTip.text: actionButton.tooltip
        Accessible.name: actionButton.label
        Accessible.role: Accessible.Button

        background: Rectangle {
            radius: 4
            color: !actionButton.enabled ? root.theme.surfaceDeep
                : actionButton.down ? root.theme.surfaceDown
                : actionButton.hovered ? root.theme.surfaceHover : root.theme.surfaceDeep
            border.width: 1
            border.color: !actionButton.enabled ? root.theme.border
                : actionButton.hovered ? root.toneColor(actionButton.tone) : root.theme.border
        }

        contentItem: Text {
            id: actionLabel
            text: actionButton.label
            color: actionButton.enabled ? root.toneColor(actionButton.tone) : root.theme.textMuted
            font.family: root.textFont
            font.pixelSize: 10
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component FilterChip: Rectangle {
        id: filterChip

        property string filterKey: ""
        property string label: ""
        property bool active: false
        signal picked()

        implicitWidth: chipText.implicitWidth + 16
        implicitHeight: 20
        radius: 3
        color: filterChip.active ? root.theme.infoFill : (chipHover.containsMouse ? root.theme.surfaceHover : root.theme.surfaceDeep)
        border.width: 1
        border.color: filterChip.active ? root.theme.info : root.theme.border

        Accessible.role: Accessible.Button
        Accessible.name: filterChip.label

        MouseArea {
            id: chipHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: filterChip.picked()
        }

        Text {
            id: chipText
            anchors.centerIn: parent
            text: filterChip.label
            color: filterChip.active ? root.theme.info : root.theme.textMuted
            font.family: root.textFont
            font.pixelSize: 9
            font.bold: filterChip.active
        }
    }

    component DetailTab: Button {
        id: tabButton

        property string label: ""
        property string tabKey: ""
        property bool selected: false
        signal picked()

        implicitWidth: tabLabel.implicitWidth + 20
        implicitHeight: 24
        padding: 0
        hoverEnabled: true
        Accessible.name: tabButton.label
        Accessible.role: Accessible.Button

        background: Rectangle {
            radius: 4
            color: tabButton.selected ? root.theme.surfaceSelect : tabButton.hovered ? root.theme.surfaceHover : root.theme.surfaceDeep
            border.width: 1
            border.color: tabButton.selected ? root.theme.accent : root.theme.border
        }

        contentItem: Text {
            id: tabLabel
            text: tabButton.label
            color: tabButton.selected ? root.theme.text : root.theme.textMuted
            font.family: root.textFont
            font.pixelSize: 10
            font.bold: tabButton.selected
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        onClicked: tabButton.picked()
    }

    component SummaryTile: Rectangle {
        id: summaryTile

        property string label: ""
        property string value: ""
        property string tone: "muted"

        implicitWidth: 120
        implicitHeight: 46
        radius: 4
        color: root.theme.bg
        border.width: 1
        border.color: root.theme.border

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 3

            Text {
                text: summaryTile.label
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 9
                font.bold: true
            }
            Text {
                Layout.fillWidth: true
                text: summaryTile.value
                color: root.toneColor(summaryTile.tone)
                font.family: root.textFont
                font.pixelSize: 12
                font.bold: true
                elide: Text.ElideRight
            }
        }
    }

    // One environment row. The status stripe, the badges and the port/probe
    // column all read the presenter projection; nothing here derives state.
    // Positioned with anchors rather than nested Layouts: three nested
    // Row/Column layouts let the port column escape the row and bleed over the
    // detail pane, so each band has an explicit width instead.
    component UnitRow: Item {
        id: unitRow

        property var rowData: null
        property bool rowSelected: false

        implicitWidth: 420
        implicitHeight: 58

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 2
            anchors.rightMargin: 2
            radius: 4
            color: unitRow.rowSelected ? root.theme.surfaceSelect : (rowHover.containsMouse ? root.theme.surfaceHover : "transparent")
            border.width: 1
            border.color: unitRow.rowSelected ? root.theme.info : "transparent"
        }

        MouseArea {
            id: rowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectUnit(unitRow.rowData, true)
            onDoubleClicked: root.openUnit(unitRow.rowData)
        }

        Rectangle {
            id: statusStripe
            x: 10
            width: 3
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 8
            anchors.bottomMargin: 8
            radius: 1.5
            color: root.toneColor(root.statusTone(unitRow.rowData ? unitRow.rowData.status : "unknown"))
            opacity: unitRow.rowData && (unitRow.rowData.status === "crash-loop" || unitRow.rowData.status === "failed") ? 0.95 : 0.5
        }

        // Left band: name + description, then status + facts. Both lines are
        // clipped to the band so a long unit name can never push the port
        // column out of the row.
        Column {
            id: leftBand
            x: 21
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 7
            anchors.bottomMargin: 7
            width: Math.max(0, unitRow.width - 21 - 124)
            spacing: 4
            clip: true

            Row {
                width: leftBand.width
                spacing: 6

                // Explicit budget, not a two-way width binding: nameText and
                // descriptionText each sized off the other, which resolved in
                // whichever order QML happened to pick and let a 4-character
                // description fragment through.
                readonly property real nameSpace: Math.max(0, leftBand.width - badgesRow.width - 14)
                readonly property real descriptionSpace: Math.max(0, nameSpace - nameText.width - 6)

                Text {
                    id: nameText
                    text: unitRow.rowData ? unitRow.rowData.unit : ""
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                    // The unit name is the row's subject; it gets the space,
                    // and the description is what elides first.
                    width: Math.min(implicitWidth, parent.nameSpace)
                }
                Text {
                    id: descriptionText
                    // Below ~10 characters the remainder ("So…") is noise, not a
                    // description; the detail pane carries the full text.
                    visible: unitRow.rowData && (unitRow.rowData.description || "").length > 0
                        && parent.descriptionSpace >= 60
                    text: unitRow.rowData ? (unitRow.rowData.description || "") : ""
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.descriptionSpace)
                }
                Row {
                    id: badgesRow
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    Badge { label: unitRow.rowData ? unitRow.rowData.kind : ""; tone: "muted" }
                    Badge {
                        visible: unitRow.rowData ? unitRow.rowData.enabled : false
                        label: "boot"
                        tone: "info"
                    }
                }
            }

            Row {
                width: leftBand.width
                spacing: 8

                Text {
                    text: unitRow.rowData ? unitRow.rowData.status : ""
                    color: root.toneColor(root.statusTone(unitRow.rowData ? unitRow.rowData.status : "unknown"))
                    font.family: root.textFont
                    font.pixelSize: 10
                    font.bold: true
                }
                Text {
                    text: unitRow.rowData ? root.rowMeta(unitRow.rowData) : ""
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 9
                    elide: Text.ElideRight
                    width: Math.max(0, leftBand.width - statusText.implicitWidth - 8)
                }
            }
        }

        Text {
            id: statusText
            visible: false
            text: unitRow.rowData ? unitRow.rowData.status : ""
            font.family: root.textFont
            font.pixelSize: 10
            font.bold: true
        }

        // Right band: the port and what the probe actually got back.
        Column {
            id: portBand
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 106
            spacing: 3

            Text {
                width: portBand.width
                text: unitRow.rowData && unitRow.rowData.port ? (":" + unitRow.rowData.port) : "no port"
                color: unitRow.rowData && unitRow.rowData.port ? root.theme.info : root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 11
                font.bold: unitRow.rowData ? unitRow.rowData.port !== null : false
                horizontalAlignment: Text.AlignRight
            }
            Text {
                width: portBand.width
                text: unitRow.rowData && unitRow.rowData.probeUp
                    ? "http " + (unitRow.rowData.probeStatus || "up")
                    : (unitRow.rowData && unitRow.rowData.port ? "no answer" : "")
                color: unitRow.rowData && unitRow.rowData.probeUp ? root.theme.goodSoft : root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 9
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    function rowMeta(unit) {
        var parts = []
        if (unit.restarts > 0) { parts.push(unit.restarts + " restarts") }
        if (unit.uptimeText) { parts.push(unit.uptimeText + (unit.sinceBoot ? " (boot)" : " up")) }
        if (unit.memoryText) { parts.push(unit.memoryText) }
        return parts.join("  ·  ")
    }

    component FactRow: RowLayout {
        property string label: ""
        property string value: ""
        property color valueColor: root.theme.text

        Layout.fillWidth: true
        spacing: 8

        Text {
            Layout.preferredWidth: 96
            text: parent.label
            color: root.theme.textMuted
            font.family: root.textFont
            font.pixelSize: 10
        }
        Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: parent.value
            color: parent.valueColor
            font.family: root.textFont
            font.pixelSize: 10
            elide: Text.ElideRight
        }
    }

    FileView {
        id: stateEventFile
        path: root.stateEventPath
        watchChanges: true
        onFileChanged: root.reloadState()
    }

    FileView {
        id: snapshotFile
        path: root.snapshotPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: snapshotAdapter
            property string generatedAt: ""
            property var view: ({})
        }
    }

    FileView {
        id: uiFile
        path: root.uiPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: uiAdapter
            property bool open: false
            property string selectedUnit: ""
            property string filter: "all"
            property string query: ""
            property string detailTab: "overview"
            property string requestedAt: ""
        }
    }

    FileView {
        id: logFile
        path: root.logPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: logAdapter
            property string unit: ""
            property string status: "idle"
            property var lines: []
            property string error: ""
            property string updatedAt: ""
        }
    }

    Component {
        id: actionFactory
        Process {
            id: actionProcess
            stdout: StdioCollector {}
            stderr: StdioCollector { id: actionErrorCollector }
            onExited: (exitCode, exitStatus) => {
                if (exitCode !== 0) {
                    root.actionError = actionErrorCollector.text.trim() || ("command failed with exit code " + exitCode)
                }
                root.pendingAction = ""
                actionProcess.destroy()
            }
        }
    }

    Process {
        id: actionRunner
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector { id: actionRunnerError }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.actionError = actionRunnerError.text.trim() || ("command failed with exit code " + exitCode)
            }
            if (root.actionQueue.length === 0)
                root.pendingAction = ""
            else
                Qt.callLater(root.startNextAction)
        }
    }

    Process {
        id: uiActionRunner
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector { id: uiActionRunnerError }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.actionError = uiActionRunnerError.text.trim() || ("command failed with exit code " + exitCode)
            }
            if (root.uiActionQueue.length > 0)
                Qt.callLater(root.startNextUiAction)
        }
    }

    Component.onCompleted: root.reloadState()

    PanelWindow {
        id: panel
        visible: uiAdapter.open
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        implicitWidth: screen ? screen.width : 1440
        implicitHeight: screen ? screen.height : 900
        color: "transparent"
        // Keep the panel surface transparent, but make the empty area an
        // outside-click dismiss target. OnDemand avoids stealing keyboard
        // focus when the popover opens.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        aboveWindows: true
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Shortcut {
            sequence: "Esc"
            context: Qt.WindowShortcut
            onActivated: root.closePanel()
        }
        Shortcut {
            sequence: "j"
            context: Qt.WindowShortcut
            onActivated: root.moveSelection(1)
        }
        Shortcut {
            sequence: "k"
            context: Qt.WindowShortcut
            onActivated: root.moveSelection(-1)
        }
        Shortcut {
            sequence: "r"
            context: Qt.WindowShortcut
            onActivated: root.refresh()
        }
        Shortcut {
            sequence: "s"
            context: Qt.WindowShortcut
            onActivated: root.dispatchFor("start", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
        }
        Shortcut {
            sequence: "t"
            context: Qt.WindowShortcut
            onActivated: root.dispatchFor("stop", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
        }
        Shortcut {
            sequence: "R"
            context: Qt.WindowShortcut
            onActivated: root.dispatchFor("restart", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
        }

        Item {
            anchors.fill: parent

            MouseArea {
                anchors.fill: parent
                onClicked: root.closePanel()
            }

            Rectangle {
                id: modalFrame
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: root.popupTopMargin
                width: Math.min(root.popupMaxWidth, Math.max(1, panel.width - 24))
                height: root.modalHeight()
                color: root.theme.bg
                border.color: root.theme.borderStrong
                border.width: 1
                radius: 8
                // Keep dead space inside the popover interactive without
                // exposing the backdrop catcher beneath the card.
                MouseArea {
                    anchors.fill: parent
                    z: -1
                }
                Keys.onEscapePressed: root.closePanel()

                ColumnLayout {
                    id: modalContent
                    anchors.fill: parent
                    anchors.margins: root.shortViewport ? 10 : 14
                    spacing: root.shortViewport ? 8 : 10

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                text: "Switchyard"
                                color: root.theme.text
                                font.family: root.textFont
                                font.pixelSize: root.shortViewport ? 20 : 22
                                font.bold: true
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !root.shortViewport || !root.narrowLayout || root.narrowPanelView === "units"
                                text: root.summaryLine()
                                color: root.theme.goodSoft
                                font.family: root.textFont
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.pendingAction.length > 0 || root.actionError.length > 0
                                text: root.actionError.length > 0 ? root.actionError : root.pendingAction
                                color: root.actionError.length > 0 ? root.theme.bad : root.theme.textMuted
                                font.family: root.textFont
                                font.pixelSize: 10
                                wrapMode: Text.Wrap
                            }
                        }

                        Button {
                            text: "Refresh"
                            onClicked: root.refresh()
                        }
                        Button {
                            text: "Close"
                            onClicked: root.closePanel()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.alerts.length > 0
                        implicitHeight: alertsColumn.implicitHeight + 18
                        color: root.theme.badFill
                        border.color: root.theme.bad
                        border.width: 1
                        radius: 4

                        ColumnLayout {
                            id: alertsColumn
                            anchors.fill: parent
                            anchors.margins: 9
                            spacing: 3

                            Repeater {
                                model: root.alerts

                                Text {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: "! " + modelData
                                    color: root.theme.bad
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }

                    Flow {
                        id: filterFlow
                        Layout.fillWidth: true
                        visible: !root.narrowLayout || root.narrowPanelView === "units" || !root.shortViewport
                        spacing: 8

                        TextField {
                            id: unitFilterInput
                            width: Math.min(320, Math.max(120, filterFlow.width * 0.48))
                            placeholderText: "filter units"
                            font.family: root.textFont
                            onTextEdited: root.runSwitchyard(["ui", "filter-query", text], "filter-query")
                            Keys.onEscapePressed: {
                                if (unitFilterInput.text.length > 0) {
                                    unitFilterInput.text = ""
                                    root.runSwitchyard(["ui", "filter-query", ""], "filter-query")
                                } else {
                                    root.closePanel()
                                }
                            }
                        }

                        Repeater {
                            model: root.filterOptions

                            FilterChip {
                                filterKey: modelData.key
                                label: modelData.label
                                active: uiAdapter.filter === modelData.key
                                onPicked: root.runSwitchyard(["ui", "filter", modelData.key], "filter")
                            }
                        }


                        Text {
                            text: root.filteredUnits().length + " shown"
                            color: root.theme.textMuted
                            font.family: root.textFont
                            font.pixelSize: 10
                        }
                    }

                    Item {
                        id: dashboardColumns
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: root.dashboardMinimumHeight()

                        RowLayout {
                            id: wideDashboard
                            anchors.fill: parent
                            visible: !root.narrowLayout
                            spacing: 10

                            Loader {
                                id: wideUnitListCard
                                Layout.preferredWidth: Math.min(420, Math.max(180, dashboardColumns.width * 0.44))
                                Layout.minimumWidth: Math.min(180, dashboardColumns.width * 0.4)
                                Layout.fillHeight: true
                                active: !root.narrowLayout
                                sourceComponent: unitListCardComponent
                            }
                            Loader {
                                id: wideDetailCard
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                active: !root.narrowLayout
                                sourceComponent: detailCardComponent
                            }
                        }

                        ColumnLayout {
                            id: narrowDashboard
                            anchors.fill: parent
                            visible: root.narrowLayout
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                DetailTab {
                                    label: "Environments"
                                    selected: root.narrowPanelView === "units"
                                    onPicked: root.narrowPanelView = "units"
                                }
                                DetailTab {
                                    label: "Selected service"
                                    selected: root.narrowPanelView === "details"
                                    enabled: root.selectedUnitEntry() !== null
                                    onPicked: root.narrowPanelView = "details"
                                }
                                Item { Layout.fillWidth: true }
                            }

                            StackLayout {
                                id: narrowPanelStack
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.minimumHeight: 0
                                currentIndex: root.narrowPanelView === "units" ? 0 : 1

                                Loader {
                                    id: narrowUnitListCard
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    active: root.narrowLayout
                                    sourceComponent: unitListCardComponent
                                }
                                Loader {
                                    id: narrowDetailCard
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    active: root.narrowLayout
                                    sourceComponent: detailCardComponent
                                }
                            }
                        }

                        Component {
                            id: unitListCardComponent

                            Rectangle {
                                id: unitListCard
                                property alias listView: unitList
                                anchors.fill: parent
                                color: root.theme.surfaceDeep
                                border.color: root.theme.border
                                border.width: 1
                                radius: 4

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 8

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Text {
                                        text: "Environments"
                                        color: root.theme.text
                                        font.family: root.textFont
                                        font.pixelSize: 11
                                        font.bold: true
                                    }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: root.filteredUnits().length + " visible" + (unitList.contentHeight > unitList.height ? " · scroll" : "")
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 10
                                    }
                                }

                                ListView {
                                    id: unitList
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumWidth: 0
                                    Layout.minimumHeight: 0
                                    clip: true
                                    spacing: 2
                                    model: root.filteredUnits()
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                    delegate: UnitRow {
                                        width: unitList.width
                                        rowData: modelData
                                        rowSelected: root.selectedIndex() === index
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: unitList.count === 0
                                        text: "No environment matches this filter."
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 11
                                    }
                                }
                            }
                        }
                        }

                        Component {
                            id: detailCardComponent

                            Rectangle {
                                id: detailCard
                                anchors.fill: parent
                                color: root.theme.surfaceDeep
                                border.color: root.theme.border
                                border.width: 1
                                radius: 4

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.shortViewport ? 8 : 12
                                spacing: root.shortViewport ? 6 : 10

                                Text {
                                    Layout.fillWidth: true
                                    text: root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "No environment selected"
                                    color: root.theme.text
                                    font.family: root.textFont
                                    font.pixelSize: 15
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: root.selectedUnitEntry() !== null && !root.shortViewport
                                    text: root.selectedUnitEntry() ? (root.selectedUnitEntry().description || "") : ""
                                    color: root.theme.textMuted
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: root.selectedUnitEntry() !== null

                                    SummaryTile {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        label: "STATE"
                                        value: root.selectedUnitEntry() ? String(root.selectedUnitEntry().status).toUpperCase() : ""
                                        tone: root.selectedUnitEntry() ? root.statusTone(root.selectedUnitEntry().status) : "muted"
                                    }
                                    SummaryTile {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        label: "LISTENER"
                                        value: root.selectedUnitEntry() && root.selectedUnitEntry().port ? (":" + root.selectedUnitEntry().port) : "NONE"
                                        tone: root.selectedUnitEntry() && root.selectedUnitEntry().port ? "info" : "muted"
                                    }
                                    SummaryTile {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        label: "HEALTH"
                                        value: root.selectedUnitEntry() && root.selectedUnitEntry().probeUp
                                            ? ("HTTP " + (root.selectedUnitEntry().probeStatus || "200"))
                                            : (root.selectedUnitEntry() && root.selectedUnitEntry().port ? "NO RESPONSE" : "NOT PROBED")
                                        tone: root.selectedUnitEntry() && root.selectedUnitEntry().probeUp ? "good"
                                            : (root.selectedUnitEntry() && root.selectedUnitEntry().port ? "warn" : "muted")
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: root.selectedUnitEntry() !== null

                                    ActionButton {
                                        label: root.selectedUnitEntry() && root.selectedUnitEntry().status === "running" ? "Stop" : "Start"
                                        tone: root.selectedUnitEntry() && root.selectedUnitEntry().status === "running" ? "bad" : "good"
                                        tooltip: "systemctl start/stop the unit"
                                        onClicked: root.dispatchFor(
                                            root.selectedUnitEntry() && root.selectedUnitEntry().status === "running" ? "stop" : "start",
                                            root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
                                    }
                                    ActionButton {
                                        label: "Restart"
                                        tone: "warn"
                                        tooltip: "Restart the unit (use this after the crash-loop is fixed)"
                                        enabled: root.selectedUnitEntry() !== null
                                        onClicked: root.dispatchFor("restart", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
                                    }
                                    ActionButton {
                                        label: "Reload"
                                        tone: "info"
                                        tooltip: "Ask systemd to reload this unit's configuration; not all units support reload"
                                        enabled: root.selectedUnitEntry() !== null
                                        onClicked: root.dispatchFor("reload", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
                                    }
                                    ActionButton {
                                        label: root.selectedUnitEntry() && root.selectedUnitEntry().enabled ? "Disable" : "Enable"
                                        tone: "info"
                                        tooltip: "Enable or disable the unit at boot"
                                        enabled: root.selectedUnitEntry() !== null
                                        onClicked: root.toggleEnabled(root.selectedUnitEntry())
                                    }
                                    ActionButton {
                                        label: "Reset failed"
                                        tone: "muted"
                                        tooltip: "systemctl reset-failed (clear the restart counter)"
                                        enabled: root.selectedUnitEntry() !== null && root.selectedUnitEntry().restarts > 0
                                        onClicked: root.dispatchFor("reset-failed", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "")
                                    }
                                    ActionButton {
                                        label: "Open"
                                        tone: "good"
                                        tooltip: "Open the served URL in the browser"
                                        enabled: root.selectedUnitEntry() !== null && root.selectedUnitEntry().port !== null
                                        onClicked: root.openUnit(root.selectedUnitEntry())
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Repeater {
                                        model: [
                                            { key: "overview", label: "Overview" },
                                            { key: "info", label: "Unit" },
                                            { key: "logs", label: "Logs" }
                                        ]

                                        DetailTab {
                                            label: modelData.label
                                            tabKey: modelData.key
                                            selected: uiAdapter.detailTab === modelData.key
                                            onPicked: {
                                                root.runSwitchyard(["ui", "tab", modelData.key], "detail-tab")
                                                if (modelData.key === "logs" && root.selectedUnitEntry())
                                                    root.runSwitchyard(["logs", root.selectedUnitEntry().unit], "logs")
                                            }
                                        }
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    color: root.theme.bg
                                    border.color: root.theme.border
                                    border.width: 1
                                    radius: 3
                                    clip: true

                                    // Overview: the presenter's facts, including the
                                    // signals that made this unit a Rails environment.
                                    Flickable {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        visible: uiAdapter.detailTab === "overview" && root.selectedUnitEntry() !== null
                                        contentWidth: width
                                        contentHeight: overviewColumn.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                        ColumnLayout {
                                            id: overviewColumn
                                            width: parent.width
                                            spacing: 6

                                            FactRow {
                                                label: "Status"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().status + "  (" + root.selectedUnitEntry().activeState + "/" + root.selectedUnitEntry().subState + ")") : ""
                                                valueColor: root.selectedUnitEntry() ? root.toneColor(root.statusTone(root.selectedUnitEntry().status)) : root.theme.text
                                            }
                                            FactRow {
                                                label: "At boot"
                                                value: root.selectedUnitEntry() && root.selectedUnitEntry().enabled ? "enabled" : "disabled"
                                            }
                                            FactRow {
                                                label: "Restarts"
                                                value: root.selectedUnitEntry() ? String(root.selectedUnitEntry().restarts) : ""
                                                valueColor: root.selectedUnitEntry() && root.selectedUnitEntry().restarts > 0 ? root.theme.warn : root.theme.text
                                            }
                                            FactRow {
                                                label: "Uptime"
                                                value: root.selectedUnitEntry()
                                                    ? ((root.selectedUnitEntry().uptimeText || "never") + (root.selectedUnitEntry().sinceBoot ? "  (started at boot)" : ""))
                                                    : ""
                                            }
                                            FactRow {
                                                label: "Main PID"
                                                value: root.selectedUnitEntry() && root.selectedUnitEntry().mainPid > 0 ? String(root.selectedUnitEntry().mainPid) : "-"
                                            }
                                            FactRow {
                                                label: "Runs as"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().user || "root") : ""
                                            }
                                            FactRow {
                                                label: "Memory"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().memoryText || "not reported") : ""
                                            }
                                            FactRow {
                                                label: "CPU"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().cpuSeconds + "s") : ""
                                            }
                                            FactRow {
                                                label: "App root"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().appRoot || "not a Rails app") : ""
                                            }
                                            FactRow {
                                                label: "Port"
                                                value: root.selectedUnitEntry() && root.selectedUnitEntry().port
                                                    ? (":" + root.selectedUnitEntry().port + "  on " + root.selectedUnitEntry().portAddress + "  (" + (root.selectedUnitEntry().portCommand || "?") + ")")
                                                    : "no listener found for this unit"
                                            }
                                            FactRow {
                                                label: "Probe"
                                                value: root.selectedUnitEntry() && root.selectedUnitEntry().probeUp
                                                    ? ("answered http " + (root.selectedUnitEntry().probeStatus || "up") + " in " + root.selectedUnitEntry().probeConnectMs + "ms")
                                                    : "no answer"
                                                valueColor: root.selectedUnitEntry() && root.selectedUnitEntry().probeUp ? root.theme.goodSoft : root.theme.textMuted
                                            }
                                            FactRow {
                                                label: "Matched by"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().signals || []).join(", ") : ""
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                visible: root.selectedUnitEntry() !== null && root.selectedUnitEntry().status === "crash-loop"
                                                text: "This unit is enabled and keeps failing: systemd restarts it every few seconds. " +
                                                      "The counter above is how many times. Read the Logs tab for the failure, then fix the app " +
                                                      "and press Restart (or run: switchyard logs " +
                                                      (root.selectedUnitEntry() ? root.selectedUnitEntry().unit : "") + ")."
                                                color: root.theme.warn
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                    }

                                    // Unit file facts: what systemd itself is configured to run.
                                    Flickable {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        visible: uiAdapter.detailTab === "info" && root.selectedUnitEntry() !== null
                                        contentWidth: width
                                        contentHeight: infoColumn.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                        ColumnLayout {
                                            id: infoColumn
                                            width: parent.width
                                            spacing: 6

                                            FactRow {
                                                label: "Working dir"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().workdir || "-") : ""
                                            }
                                            FactRow {
                                                label: "Unit file"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().fragmentPath || "-") : ""
                                            }
                                            FactRow {
                                                label: "Unit state"
                                                value: root.selectedUnitEntry() ? root.selectedUnitEntry().unitFileState : ""
                                            }
                                            FactRow {
                                                label: "Kind"
                                                value: root.selectedUnitEntry() ? root.selectedUnitEntry().kind : ""
                                            }
                                            FactRow {
                                                label: "Load"
                                                value: root.selectedUnitEntry() ? root.selectedUnitEntry().loadState : ""
                                            }
                                            FactRow {
                                                label: "PIDs"
                                                value: root.selectedUnitEntry() ? (root.selectedUnitEntry().portPids || []).join(", ") : ""
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                text: root.selectedUnitEntry() && root.selectedUnitEntry().port
                                                    ? "Switchyard pairs this unit with its port by reading the unit cgroup, so a server started through bundle exec is still matched."
                                                    : "No listening socket was found in this unit's cgroup. Start the environment to give it a port."
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                    }

                                    // Logs: fetched on demand through the daemon into log.json.
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        visible: uiAdapter.detailTab === "logs" && root.selectedUnitEntry() !== null
                                        spacing: 6

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8

                                            Text {
                                                Layout.fillWidth: true
                                                text: logAdapter.status === "loading" ? "Reading the journal…"
                                                    : (logAdapter.status === "error" ? logAdapter.error : (logAdapter.unit + "  ·  last " + logAdapter.lines.length + " lines"))
                                                color: logAdapter.status === "error" ? root.theme.bad : root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                                elide: Text.ElideRight
                                            }
                                            BusyIndicator {
                                                Layout.preferredWidth: 20
                                                Layout.preferredHeight: 20
                                                running: logAdapter.status === "loading"
                                                visible: running
                                            }
                                            ActionButton {
                                                label: "Reload"
                                                tone: "info"
                                                tooltip: "Re-read the journal for this unit"
                                                onClicked: root.runSwitchyard(["logs", root.selectedUnitEntry() ? root.selectedUnitEntry().unit : ""])
                                            }
                                        }

                                        Flickable {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            contentWidth: width
                                            contentHeight: logColumn.implicitHeight
                                            clip: true
                                            boundsBehavior: Flickable.StopAtBounds
                                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                            Column {
                                                id: logColumn
                                                width: parent.width
                                                spacing: 1

                                                Repeater {
                                                    model: logAdapter.lines

                                                    Text {
                                                        width: logColumn.width
                                                        text: modelData
                                                        color: String(modelData).indexOf("error") >= 0 || String(modelData).indexOf("Error") >= 0
                                                            ? root.theme.bad : root.theme.text
                                                        font.family: root.textFont
                                                        font.pixelSize: 9
                                                        wrapMode: Text.WrapAnywhere
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            visible: logAdapter.status === "ready" && logAdapter.lines.length === 0
                                            text: "The journal has no entries for this unit."
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 11
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.selectedUnitEntry() === null
                                        text: "Select an environment"
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 11
                                    }
                                }
                            }
                        }
                        }
                    }
                }
            }
        }
    }
}
