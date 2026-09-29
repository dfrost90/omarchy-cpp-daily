pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
    id: root
    moduleName: "io.github.dfrost90.cpp-daily"
    ipcTarget: moduleName
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("scripts/cpp_daily.py").toString().replace(/^file:\/\//, ""))
    property var report: ({})
    property string message: ""
    property string solution: ""
    property bool hintsVisible: false
    property bool libraryVisible: false
    property bool busy: false
    readonly property var task: report.task || ({})
    readonly property color fg: bar ? bar.foreground : Color.foreground
    readonly property string face: bar ? bar.fontFamily : Style.font.family
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function request(action, value) {
        if (busy) return;
        busy = true;
        if (["track", "select", "next"].indexOf(action) >= 0) message = "";
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
            if (next.task.id !== task.id) { hintsVisible = false; solution = ""; scroll.contentY = 0; }
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
        text: "C++" + (root.report.todayDone ? " ✓" : " ·")
        active: root.opened
        tooltipText: "C++ Daily · " + (root.report.completed || 0) + "/" + (root.report.total || 18) + " practiced"
        onPressed: root.toggle()
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
        bordered: true
        fontFamily: root.face
        fontSize: Style.font.bodySmall
        foreground: root.fg
        enabled: !root.busy
        opacity: enabled ? 1 : 0.5
    }
    KeyboardPanel {
        id: popup
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: fittedContentWidth(Style.space(540))
        contentHeight: fittedContentHeight(column.implicitHeight, Style.space(740))
        focusTarget: keys
        Item {
            id: keys
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
                        Copy { text: "C++ DAILY"; color: Color.accent; font.bold: true; font.pixelSize: Style.font.subtitle }
                        Copy { text: "Small sessions. Lasting understanding."; opacity: 0.7 }
                        Copy {
                            visible: !root.report.track
                            text: "Choose your starting point. Every task has an original exercise and a LearnCpp reading link. You can change paths later without losing progress."
                        }
                        Flow {
                            width: parent.width; spacing: Style.space(8)
                            Action { text: "Beginner"; selected: root.report.track === "beginner"; onClicked: root.request("track", "beginner") }
                            Action { text: "Returning to C++"; selected: root.report.track === "returning"; onClicked: root.request("track", "returning") }
                        }
                        Copy {
                            visible: !!root.report.track
                            text: (root.report.completed || 0) + " / " + (root.report.total || 18) + " practiced  ·  " + (root.report.streak || 0) + " day streak  ·  " + (root.report.due || 0) + " due for review"
                        }
                        Copy { visible: !root.report.track && !!root.message; text: root.message; color: Color.accent }
                        Rectangle {
                            width: parent.width; height: Style.space(4)
                            color: Qt.alpha(root.fg, 0.15)
                            Rectangle { height: parent.height; width: parent.width * (root.report.completed || 0) / (root.report.total || 18); color: Color.accent }
                        }
                        Column {
                            width: parent.width; spacing: Style.spacing.md
                            visible: !!root.report.track
                            Copy { text: (root.task.minutes || 10) + " MINUTES  /  CHAPTER " + (root.task.chapter || 1); opacity: 0.6 }
                            Copy { text: root.task.title || "Loading…"; font.pixelSize: Style.font.subtitle; font.bold: true }
                            Copy { text: root.task.prompt || "" }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { text: "Start practice ↗"; selected: true; onClicked: { root.request("start"); root.close(); } }
                                Action { text: "Read on LearnCpp ↗"; onClicked: { Qt.openUrlExternally(root.task.url); root.close(); } }
                            }
                            Copy { text: "Save answer.cpp in your editor, then check it here. Code runs locally as your user."; opacity: 0.6 }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { text: root.busy ? "Working…" : "Check code"; onClicked: root.request("check") }
                                Action { text: root.hintsVisible ? "Hide hint" : "Show hint"; onClicked: root.hintsVisible = !root.hintsVisible }
                                Action { text: root.solution ? "Hide solution" : "Reveal solution"; onClicked: root.solution ? root.solution = "" : root.request("solution") }
                            }
                            Copy { visible: root.hintsVisible; text: (root.task.hints || []).join("\n"); color: Color.accent }
                            Copy { visible: !!root.solution; text: root.solution; font.family: "monospace" }
                            Copy { visible: !!root.solution; text: root.task.explanation || "" }
                            Copy { visible: !!root.message; text: root.message; color: Color.accent }
                            PanelSeparator { width: parent.width; foreground: root.fg }
                            Copy { text: "AFTER PRACTISING"; opacity: 0.6 }
                            Copy { text: "Rate your understanding to save this session. These are self-assessments; passing checks alone does not mark a task complete."; opacity: 0.75 }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { text: "Review tomorrow"; onClicked: root.request("rate", "again") }
                                Action { text: "Understood"; onClicked: root.request("rate", "good") }
                                Action { text: "Next task →"; onClicked: { root.message = ""; root.request("next"); } }
                            }
                            Copy { visible: !!(root.report.record || {}).due; text: "Next review: " + ((root.report.record || {}).due || "") }
                            Copy { visible: !!root.report.todayDone; text: "Today's practice is saved. Stop here or keep exploring—your pace is yours."; opacity: 0.7 }
                            PanelSeparator { width: parent.width; foreground: root.fg }
                            Flow {
                                width: parent.width; spacing: Style.space(8)
                                Action { text: root.libraryVisible ? "Hide task library" : "Browse tasks"; onClicked: root.libraryVisible = !root.libraryVisible }
                                Action { text: "Snooze 1 hour"; onClicked: root.request("snooze") }
                            }
                            Column {
                                width: parent.width; spacing: Style.space(4); visible: root.libraryVisible
                                Repeater {
                                    model: root.libraryVisible ? (root.report.history || []) : []
                                    delegate: Action {
                                        required property var modelData
                                        width: parent.width
                                        leftAlign: true
                                        text: (modelData.completed ? "✓ " : "· ") + modelData.title
                                        selected: root.task.id === modelData.id
                                        onClicked: { root.message = ""; root.request("select", modelData.id); }
                                    }
                                }
                            }
                        }
                        Copy {
                            text: root.setting("reminders", true) ? "Reminder at " + root.setting("reminderTime", "19:00") + " local time, while the widget is running. Change or disable it in bar widget settings." : "Reminders are off. Enable them in bar widget settings."
                            opacity: 0.6
                        }
                        Copy { text: "Independent project. Not affiliated with LearnCpp.com. Lessons open on their website; exercises and progress stay here."; opacity: 0.55; font.pixelSize: Style.font.caption }
                    }
                }
            }
        }
    }
}
