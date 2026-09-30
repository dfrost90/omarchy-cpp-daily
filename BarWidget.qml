pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "ui/CppSyntax.js" as CppSyntax

Panel {
    id: root
    moduleName: "io.github.dfrost90.cpp-daily"
    ipcTarget: moduleName
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("scripts/cpp_daily.py").toString().replace(/^file:\/\//, ""))
    property var report: ({})
    property string message: ""
    property string solution: ""
    property bool hintsVisible: false
    property bool explanationVisible: false
    property string taskSearch: ""
    property int taskPage: 0
    readonly property int pageSize: 8
    readonly property var filteredTasks: (report.history || []).filter(function(t) {
        var query = root.taskSearch.trim().toLowerCase();
        return (t.title + " " + t.topic).toLowerCase().indexOf(query) >= 0;
    })
    readonly property int pageCount: Math.max(1, Math.ceil(filteredTasks.length / pageSize))
    onTaskSearchChanged: taskPage = 0
    onPageCountChanged: if (taskPage >= pageCount) taskPage = pageCount - 1
    property bool libraryVisible: false
    property bool detailsVisible: false
    property bool keepOpen: false
    property bool busy: false
    readonly property var task: report.task || ({})
    readonly property color fg: bar ? bar.foreground : Color.foreground
    readonly property string face: bar ? bar.fontFamily : Style.font.family
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function request(action, value) {
        if (busy) return;
        busy = true;
        if (["track", "select", "next", "solution", "rate"].indexOf(action) >= 0) message = "";
        var args = ["python3", helper, action];
        if (value !== undefined) args.push(value);
        if (task.id) args.push("--task", task.id);
        if (action === "tick") args.push("--reminders", String(setting("reminders", true)), "--time", String(setting("reminderTime", "19:00")));
        worker.command = args;
        worker.running = true;
    }
    function accept(text) {
        try {
            var next = JSON.parse(text);
            if (next.error) { message = next.error; return; }
            if (next.task.id !== task.id) { hintsVisible = false; explanationVisible = false; solution = ""; scroll.contentY = 0; }
            report = next;
            if (next.message) message = next.message;
            if (next.solution) solution = next.solution;
        } catch (error) { message = "Could not read progress: " + error; }
    }
    Component.onCompleted: request("status")
    onOpenedChanged: if (opened) request("status")
    Process {
        id: worker
        stdout: StdioCollector { onStreamFinished: root.accept(text) }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.message = text.trim().slice(0, 2000) }
        onExited: root.busy = false
    }
    Timer {
        interval: 60000; repeat: true; running: true
        onTriggered: root.request("tick")
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\ue61d"
        fontFamily: "FiraCode Nerd Font"
        fontSize: Style.font.icon
        active: root.opened
        tooltipText: "C++ Daily · " + (root.report.completed || 0) + "/" + (root.report.total || 100) + " practiced"
        onPressed: root.toggle()
        Rectangle {
            visible: !!root.report.todayDone
            width: Style.space(4); height: width; radius: width / 2
            anchors.right: parent.right; anchors.top: parent.top
            anchors.rightMargin: Style.space(4); anchors.topMargin: Style.space(4)
            color: Color.accent
        }
    }
    component Copy: Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.fg
        font.family: root.face
        font.pixelSize: Style.font.bodySmall
    }
    component Action: Button {
        focusable: true
        iconSize: Style.font.bodySmall
        Accessible.role: Accessible.Button
        Accessible.name: text
        bordered: true
        fontFamily: root.face
        fontSize: Style.font.bodySmall
        foreground: root.fg
        enabled: !root.busy
        opacity: enabled ? 1 : 0.5
    }
    // A small independent layer surface lets clicks reach the editor and bar.
    // Reparent the same content, preserving task state and scroll position.
    PanelWindow {
        id: pinned
        visible: root.opened && root.keepOpen
        screen: popup.screen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "cpp-daily-pinned"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors { top: true; left: true }
        margins { top: popup.cardOrigin.y; left: popup.cardOrigin.x }
        implicitWidth: popup.contentWidth
        implicitHeight: popup.contentHeight
        BorderSurface {
            anchors.fill: parent
            color: Color.popups.background
            borderSpec: popup.borderSpec
            padding: popup.padding
            radius: Style.cornerRadius
            Item {
                id: pinnedHost
                anchors.fill: parent
                anchors.topMargin: parent.contentTopInset
                anchors.bottomMargin: parent.contentBottomInset
                anchors.leftMargin: parent.contentLeftInset
                anchors.rightMargin: parent.contentRightInset
            }
        }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened && !root.keepOpen
        contentWidth: fittedContentWidth(Style.space(540))
        contentHeight: fittedContentHeight(column.implicitHeight, Style.space(740))
        focusTarget: keys
        Item { id: popupHost; anchors.fill: parent }
        Item {
            id: keys
            parent: root.keepOpen ? pinnedHost : popupHost
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()
            Controls.ScrollView {
                anchors.fill: parent
                contentWidth: availableWidth
                Flickable {
                    id: scroll
                    clip: true
                    contentWidth: width
                    contentHeight: column.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: column
                        width: scroll.width - Style.space(12)
                        spacing: Style.spacing.md
                        RowLayout {
                            width: parent.width
                            spacing: Style.space(8)
                            Text {
                                text: "C++ DAILY"; textFormat: Text.PlainText
                                color: Color.accent; font.family: root.face
                                font.bold: true; font.pixelSize: Style.font.subtitle
                                Layout.fillWidth: true
                            }
                            Text {
                                text: "Keep open"; textFormat: Text.PlainText
                                color: root.fg; font.family: root.face
                                font.pixelSize: Style.font.caption
                            }
                            ToggleSwitch {
                                checked: root.keepOpen
                                trackHeight: Style.space(16)
                                activeFocusOnTab: true
                                hasCursor: activeFocus
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: "Keep open"
                                Accessible.checked: checked
                                onToggled: root.keepOpen = !root.keepOpen
                                Keys.onSpacePressed: root.keepOpen = !root.keepOpen
                                Keys.onReturnPressed: root.keepOpen = !root.keepOpen
                            }
                        }
                        Copy {
                            visible: !root.report.track
                            text: "Choose a starting point. You can change it later."
                        }
                        Flow {
                            visible: !root.report.track || root.libraryVisible
                            width: parent.width; spacing: Style.space(8)
                            Action { iconText: "\uf19d"; text: "Beginner"; selected: root.report.track === "beginner"; onClicked: root.request("track", "beginner") }
                            Action { iconText: "\uf01e"; text: "Returning to C++"; selected: root.report.track === "returning"; onClicked: root.request("track", "returning") }
                        }
                        Copy {
                            visible: !!root.report.track
                            text: (root.report.completed || 0) + " / " + (root.report.total || 100) + " tasks  ·  " + (root.report.streak || 0) + "-day streak  ·  " + (root.report.due || 0) + " reviews due"
                        }
                        Copy { visible: !root.report.track && !!root.message; text: root.message; color: Color.accent }
                        Rectangle {
                            width: parent.width; height: Style.space(4)
                            color: Qt.alpha(root.fg, 0.15)
                            Rectangle { height: parent.height; width: parent.width * (root.report.completed || 0) / (root.report.total || 100); color: Color.accent }
                        }
                        Column {
                            width: parent.width; spacing: Style.spacing.md
                            visible: !!root.report.track
                            Rectangle {
                                width: parent.width
                                implicitHeight: taskContent.implicitHeight + Style.space(24)
                                color: Qt.alpha(Color.accent, 0.06)
                                border.color: Qt.alpha(Color.accent, 0.35)
                                border.width: 1
                                radius: Style.cornerRadius
                                Column {
                                    id: taskContent
                                    x: Style.space(12); y: Style.space(12)
                                    width: parent.width - Style.space(24)
                                    spacing: Style.space(8)
                                    Copy { text: (root.task.minutes || 10) + " min · " + (root.task.topic || "Core recap"); opacity: 0.7 }
                                    Copy { text: root.task.title || "Loading…"; font.pixelSize: Style.font.subtitle; font.bold: true }
                                    Copy { text: root.task.prompt || "" }
                                }
                            }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { iconText: "\uf044"; text: "Open editor"; tooltipText: "Edit answer.cpp, save, then check your code here."; selected: true; onClicked: { root.request("start"); if (!root.keepOpen) root.close(); } }
                                Action { iconText: "\uf02d"; text: "LearnCpp"; tooltipText: "Read the explanation on LearnCpp.com"; onClicked: { Qt.openUrlExternally(root.task.url); if (!root.keepOpen) root.close(); } }
                            }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { iconText: "\uf04b"; text: root.busy ? "Working…" : "Check code"; tooltipText: "Compile and run your saved answer locally as your user."; onClicked: root.request("check") }
                                Action { iconText: "\uf0eb"; text: root.hintsVisible ? "Hide hint" : "Hint"; onClicked: root.hintsVisible = !root.hintsVisible }
                                Action { iconText: "\uf05a"; text: root.explanationVisible ? "Hide explanation" : "Explain"; onClicked: root.explanationVisible = !root.explanationVisible }
                                Action { iconText: "\uf121"; text: root.solution ? "Hide solution" : "Solution"; onClicked: root.solution ? root.solution = "" : root.request("solution") }
                            }
                            Copy { visible: root.hintsVisible; text: (root.task.hints || []).join("\n"); color: Color.accent }
                            Rectangle {
                                visible: !!root.solution
                                width: parent.width
                                implicitHeight: codeColumn.implicitHeight + Style.space(24)
                                color: Qt.alpha(root.fg, 0.045)
                                border.color: Qt.alpha(root.fg, 0.2)
                                border.width: 1
                                radius: Style.cornerRadius
                                Column {
                                    id: codeColumn
                                    x: Style.space(12); y: Style.space(12)
                                    width: parent.width - Style.space(24)
                                    spacing: Style.space(8)
                                    Copy { text: "C++ · Reference solution"; opacity: 0.7; font.pixelSize: Style.font.caption }
                                    TextEdit {
                                        width: parent.width
                                        readOnly: true
                                        selectByMouse: true
                                        activeFocusOnTab: true
                                        textFormat: TextEdit.RichText
                                        wrapMode: TextEdit.Wrap
                                        color: root.fg
                                        selectionColor: Color.accent
                                        selectedTextColor: Color.popups.background
                                        font.family: "FiraCode Nerd Font"
                                        font.pixelSize: Style.font.bodySmall
                                        Accessible.name: "C++ reference solution"
                                        readonly property bool light: Color.popups.background.hslLightness > 0.5
                                        text: CppSyntax.highlight(root.solution, {
                                            keyword: light ? "#7535a5" : "#c4a7e7",
                                            string: light ? "#267045" : "#a6d9a0",
                                            number: light ? "#925600" : "#efc078",
                                            comment: light ? "#586777" : "#99a6ba"
                                        })
                                    }
                                }
                            }
                            Copy { visible: root.explanationVisible; text: root.task.explanation || "" }
                            Copy { visible: !!root.message; text: root.message; color: Color.accent }
                            PanelSeparator { width: parent.width; foreground: root.fg }
                            Copy { text: "How did it go?"; opacity: 0.7 }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { iconText: "\uf017"; text: "Review tomorrow"; tooltipText: "Save this session and practise again tomorrow."; onClicked: root.request("rate", "again") }
                                Action { iconText: "\uf00c"; text: "Understood"; tooltipText: "Save this session and schedule a later review."; onClicked: root.request("rate", "good") }
                                Action { iconText: "\uf061"; text: "Next task"; enabled: !root.busy && !!root.report.nextAvailable; tooltipText: "Save a confidence rating to continue, or choose a task from All tasks."; onClicked: { root.message = ""; root.request("next"); } }
                            }
                            Copy { visible: !!root.report.allPracticed && !root.report.due; text: "All tasks practised. Come back for scheduled reviews."; opacity: 0.7 }
                            Copy { visible: !!(root.report.record || {}).due; text: "Saved · review on " + ((root.report.record || {}).due || "") }
                            PanelSeparator { width: parent.width; foreground: root.fg }
                            Column {
                                width: parent.width; spacing: Style.space(4); visible: root.libraryVisible
                                TextField {
                                    width: parent.width
                                    placeholderText: "Search tasks or topics…"
                                    Accessible.name: "Search tasks or topics"
                                    text: root.taskSearch
                                    onTextChanged: root.taskSearch = text
                                }
                                Copy { text: root.filteredTasks.length + " tasks · page " + (root.taskPage + 1) + "/" + root.pageCount; opacity: 0.6 }
                                Repeater {
                                    model: root.libraryVisible ? root.filteredTasks.slice(root.taskPage * root.pageSize, (root.taskPage + 1) * root.pageSize) : []
                                    delegate: Action {
                                        required property var modelData
                                        width: parent.width
                                        leftAlign: true
                                        iconText: modelData.completed ? "\uf00c" : "\uf105"
                                        text: modelData.title
                                        selected: root.task.id === modelData.id
                                        tooltipText: modelData.topic
                                        onClicked: { root.message = ""; root.request("select", modelData.id); root.libraryVisible = false; }
                                    }
                                }
                                Copy { visible: root.filteredTasks.length === 0; text: "No matching tasks." }
                                Flow {
                                    width: parent.width; spacing: Style.space(8)
                                    Action { iconText: "\uf060"; text: "Previous"; enabled: root.taskPage > 0; onClicked: root.taskPage-- }
                                    Action { iconText: "\uf061"; text: "More"; enabled: root.taskPage + 1 < root.pageCount; onClicked: root.taskPage++ }
                                }
                            }
                        }
                        Flow {
                            width: parent.width; spacing: Style.space(8)
                            Action { iconText: "\uf03a"; text: root.libraryVisible ? "Hide tasks" : "All tasks"; bordered: false; onClicked: root.libraryVisible = !root.libraryVisible }
                            Action {
                                iconText: "\uf0f3"
                                text: root.setting("reminders", true) ? "Reminder " + root.setting("reminderTime", "19:00") : "Reminders off"
                                bordered: false
                                enabled: !root.busy && root.setting("reminders", true)
                                tooltipText: "Click to snooze for one hour. Change reminder settings in bar widget settings."
                                onClicked: root.request("snooze")
                            }
                            Action { iconText: "\uf05a"; text: "About"; bordered: false; selected: root.detailsVisible; onClicked: root.detailsVisible = !root.detailsVisible }
                            Action { iconText: "\uf00d"; text: "Close"; bordered: false; enabled: true; onClicked: root.close() }
                        }
                        Copy {
                            visible: root.detailsVisible
                            text: "Original exercises with LearnCpp reading links. Independent and unaffiliated with LearnCpp.com. Progress stays on your device. Checks run your code locally; ratings save your progress. Reminders use local time while this widget is running."
                            opacity: 0.6; font.pixelSize: Style.font.caption
                        }
                    }
                }
            }
        }
    }
}
