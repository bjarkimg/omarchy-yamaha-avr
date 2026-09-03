import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.bjarkimg.yamaha-avr"

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  property bool online: false
  property bool sessionReady: false
  property bool muted: false
  property string statusText: "READY"
  property string processError: ""
  property string viewMode: "remote"
  property string activeName: deviceName
  property string activeHost: host
  property string power: ""
  property string inputSel: ""
  property string program: ""
  property string volumeLabel: ""
  property bool straightOn: false
  property bool pureOn: false
  property bool sevenOn: false
  property int dialogueLift: 0
  property int lrBalance: 0
  property bool seatBusy: false
  property var actionQueue: []
  property string bass: "+0.0"
  property int bassVal: 0
  property string treble: "+0.0"
  property int trebleVal: 0
  property string subTrim: "+0.0"
  property int subTrimVal: 0
  property bool extraBassOn: false
  property bool ypaoVolOn: false
  property bool adaptDrcOn: false
  property bool enhancerOn: false
  property bool cinema3dOn: false
  property int dialogueLvl: 0

  readonly property string deviceName: String(setting("deviceName", "Yamaha AVR"))
  readonly property string host: String(setting("host", ""))
  readonly property string remotePath: decodeURIComponent(
    String(Qt.resolvedUrl("yamaha-avr")).replace(/^file:\/\//, "")
  )
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.58)
  readonly property color accent: bar ? bar.urgent : Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"

  function close() {
    popupOpen = false
    viewMode = "remote"
    actionQueue = []
  }

  function applyStatus(message) {
    if (message.name) activeName = String(message.name)
    if (message.host) activeHost = String(message.host)
    power = String(message.power || power)
    muted = String(message.mute || "").toLowerCase() === "on"
    inputSel = String(message.input || inputSel)
    program = String(message.program || program)
    pureOn = String(message.pureDirect || "").toLowerCase() === "on"
    straightOn = String(message.straight || "").toLowerCase() === "on" && !pureOn
    sevenOn = String(program).indexOf("7ch") >= 0 && !straightOn && !pureOn
    if (message.bass !== undefined && message.bass !== null && message.bass !== "") bass = String(message.bass)
    if (message.bassVal !== undefined && message.bassVal !== null && message.bassVal !== "") bassVal = Number(message.bassVal)
    if (message.treble !== undefined && message.treble !== null && message.treble !== "") treble = String(message.treble)
    if (message.trebleVal !== undefined && message.trebleVal !== null && message.trebleVal !== "") trebleVal = Number(message.trebleVal)
    if (message.subTrim !== undefined && message.subTrim !== null && message.subTrim !== "") subTrim = String(message.subTrim)
    if (message.subTrimVal !== undefined && message.subTrimVal !== null && message.subTrimVal !== "") subTrimVal = Number(message.subTrimVal)
    extraBassOn = String(message.extraBass || "").toLowerCase() === "auto"
    ypaoVolOn = String(message.ypaoVolume || "").toLowerCase() === "auto"
    adaptDrcOn = String(message.adaptiveDrc || "").toLowerCase() === "auto"
    enhancerOn = String(message.enhancer || "").toLowerCase() === "on"
    cinema3dOn = String(message.cinema3d || "").toLowerCase() === "auto" || String(message.cinema3d || "").toLowerCase() === "on"
    if (message.dialogueLvl !== undefined && message.dialogueLvl !== null && message.dialogueLvl !== "")
      dialogueLvl = Math.max(0, Math.min(3, Number(message.dialogueLvl)))
    if (!seatBusy && message.dialogueLift !== undefined && message.dialogueLift !== null && message.dialogueLift !== "")
      dialogueLift = Math.max(0, Math.min(5, Number(message.dialogueLift)))
    if (!seatBusy && message.lrBalance !== undefined && message.lrBalance !== null && message.lrBalance !== "")
      lrBalance = Math.max(-5, Math.min(5, Number(message.lrBalance)))
    if (message.volumeDb !== undefined && message.volumeDb !== null && message.volumeDb !== "")
      volumeLabel = Number(message.volumeDb).toFixed(1) + " dB"
    else if (message.volume !== undefined && message.volume !== null && message.volume !== "" && message.volume !== "--")
      volumeLabel = String(message.volume) + " dB"
    online = String(message.power || "").toLowerCase() === "on" || Boolean(message.connected)
    if (String(message.status) === "standby" || String(message.power || "").toLowerCase() === "standby") {
      online = false
      statusText = "STANDBY"
    } else if (String(message.status) === "awake" || String(message.power || "").toLowerCase() === "on") {
      online = true
      statusText = muted ? "MUTED" : (inputSel || "ON")
    } else if (online) {
      statusText = muted ? "MUTED" : (inputSel || "ON")
    } else {
      statusText = "OFFLINE"
    }
  }

  function sendAction(action) {
    if (!action) return
    if (sessionProcess.running && sessionReady) {
      statusText = String(action).toUpperCase().replace(/-/g, " ")
      sessionProcess.write(action + "\n")
      return
    }
    if (actionQueue.length < 32) actionQueue = actionQueue.concat([action])
  }

  function sendRequest(request) {
    if (!sessionProcess.running) return false
    sessionProcess.write(JSON.stringify(request) + "\n")
    return true
  }

  function flushQueuedActions() {
    if (!sessionProcess.running || !sessionReady || actionQueue.length === 0) return
    var pending = actionQueue
    actionQueue = []
    for (var i = 0; i < pending.length; i++) sessionProcess.write(pending[i] + "\n")
  }

  function setHost() {
    var value = String(hostInput.text || "").trim()
    if (!value) {
      processError = "Enter the receiver IP"
      return
    }
    processError = ""
    statusText = "CONNECTING"
    sendRequest({ "op": "set-host", "host": value, "name": String(nameInput.text || "").trim() })
  }

  function handleSessionLine(line) {
    var message
    try { message = JSON.parse(String(line || "")) } catch (error) { return }

    if (message.event === "ready" || message.event === "switched") {
      sessionReady = true
      processError = ""
      applyStatus(message)
      flushQueuedActions()
      if (message.event === "switched") viewMode = "remote"
      return
    }
    if (message.event === "error") {
      online = Boolean(message.connected)
      processError = String(message.message || "")
      if (!online) {
        statusText = "OFFLINE"
      }
      return
    }
    if (message.event !== "result") return
    processError = ""
    applyStatus(message)
  }

  function handleTextKey(text) {
    var key = String(text || "").toLowerCase()
    if (viewMode === "devices" || viewMode === "audio") {
      if (key === "b" || key === "q") { viewMode = "remote"; return }
      if (viewMode === "audio") {
        if (key === "e") sendAction("extra-bass-toggle")
        else if (key === "y") sendAction("ypao-volume-toggle")
        else if (key === "d") sendAction("adaptive-drc-toggle")
        else if (key === "h") sendAction("enhancer-toggle")
        else if (key === "c") sendAction("cinema3d-toggle")
        return
      }
      return
    }
    if (key === "p") sendAction("power")
    else if (key === "o") sendAction("power-on")
    else if (key === "x" || key === "f") sendAction("power-off")
    else if (key === "m") sendAction("mute")
    else if (key === "+" || key === "=") sendAction("volume-up")
    else if (key === "-" || key === "_") sendAction("volume-down")
    else if (key === "1") sendAction("input-hdmi1")
    else if (key === "2") sendAction("input-hdmi2")
    else if (key === "3") sendAction("input-hdmi3")
    else if (key === "4") sendAction("input-hdmi4")
    else if (key === "5") sendAction("input-hdmi5")
    else if (key === "s") sendAction("straight")
    else if (key === "u") sendAction("pure-direct")
    else if (key === "7") sendAction("program-7ch")
    else if (key === "a") viewMode = "audio"
    else if (key === "d") {
      hostInput.text = root.activeHost
      nameInput.text = root.activeName
      viewMode = "devices"
    }
    else if (key === "q") close()
  }

  onPopupOpenChanged: {
    if (!popupOpen) return
    sendAction("status")
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      room.placeSeat()
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property int restartAttempts: 0
  readonly property int maxRestartAttempts: 5

  function manualReconnect() {
    restartAttempts = 0
    root.processError = ""
    sessionProcess.running = false
    sessionProcess.running = true
  }

  Process {
    id: sessionProcess
    command: [root.remotePath, "--host", root.host, "--name", root.deviceName, "session"]
    environment: ({
      "PATH": "/usr/bin:/bin",
      "HOME": Quickshell.env("HOME") || "",
      "XDG_STATE_HOME": Quickshell.env("XDG_STATE_HOME") || "",
      "LC_ALL": "C.UTF-8"
    })
    stdinEnabled: true
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (line && line.length <= 65536) {
          root.restartAttempts = 0
          root.handleSessionLine(line)
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (line) root.processError = String(line).slice(0, 512).trim()
      }
    }
    onExited: function() {
      root.sessionReady = false
      root.online = false
      root.statusText = "OFFLINE"
      if (root.restartAttempts < root.maxRestartAttempts) {
        root.restartAttempts++
        var delay = Math.min(10000, 1000 * Math.pow(2, root.restartAttempts - 1))
        sessionRestart.interval = delay
        sessionRestart.restart()
      } else {
        root.processError = "Backend stopped after multiple failures. Open settings to reconnect."
      }
    }
  }

  Timer {
    id: sessionRestart
    interval: 1500
    repeat: false
    onTriggered: { if (!sessionProcess.running) sessionProcess.running = true }
  }

  component RemoteKey: Button {
    property string action: ""
    property bool on: false
    property real keyWidth: 92
    property real keyHeight: 38
    width: keyWidth
    height: keyHeight
    selected: on
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    iconSize: Style.font.iconLarge
    bordered: true
    onClicked: root.sendAction(action)
  }

  component ToneRow: Row {
    id: toneRow
    property string title: ""
    property string displayValue: "+0.0 dB"
    property string actionDown: ""
    property string actionUp: ""
    property string setOp: ""
    property string tooltipInfo: ""
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(6)

    Item {
      width: 70
      height: 34

      Text {
        anchors.fill: parent
        verticalAlignment: Text.AlignVCenter
        text: toneRow.title
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      MouseArea {
        id: titleHover
        anchors.fill: parent
        hoverEnabled: true
      }

      PanelToolTip {
        visible: titleHover.containsMouse && toneRow.tooltipInfo !== ""
        text: toneRow.tooltipInfo
        panelForeground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    Button {
      width: 42
      height: 34
      text: "−"
      tooltipText: "Decrease " + toneRow.title
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: root.sendAction(toneRow.actionDown)
    }

    Text {
      width: 65
      height: 34
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: toneRow.displayValue
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Button {
      width: 42
      height: 34
      text: "+"
      tooltipText: "Increase " + toneRow.title
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: root.sendAction(toneRow.actionUp)
    }

    Button {
      width: 42
      height: 34
      text: "0"
      tooltipText: "Reset " + toneRow.title + " to 0.0 dB"
      foreground: root.dim
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: root.sendRequest({ "op": toneRow.setOp, "value": 0 })
    }
  }

  component PillButton: Button {
    property bool on: false
    property real pillWidth: 67
    property real pillHeight: 32
    width: pillWidth
    height: pillHeight
    selected: on
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    bordered: true
  }

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: Style.bar.statusSlot
    implicitHeight: Style.bar.sizeHorizontal

    Text {
      anchors.centerIn: parent
      text: "AV"
      textFormat: Text.PlainText
      color: root.online ? root.foreground : root.dim
      font.family: "sans-serif"
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) {
          root.sendAction("power")
        } else {
          root.popupOpen = !root.popupOpen
        }
      }
      onEntered: if (root.bar) root.bar.showTooltip(root, root.activeName + " · " + (root.online ? "ON" : "STANDBY"))
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(332))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostInput.activeFocus || nameInput.activeFocus
      onCloseRequested: {
        if (root.viewMode === "remote") root.close()
        else root.viewMode = "remote"
      }
      onTextKey: function(text) { root.handleTextKey(text) }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(titleCol.implicitHeight, statusLabel.implicitHeight)
          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            Text {
              text: root.activeName.toUpperCase()
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              text: root.viewMode === "remote" ? "YAMAHA AVR" : (root.viewMode === "audio" ? "AUDIO CONTROLS" : "RECEIVER HOST")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            id: statusLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (root.online ? "● " : "○ ") + root.statusText
            textFormat: Text.PlainText
            color: root.online ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Column {
          visible: root.viewMode === "remote"
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: (root.muted ? "MUTE  ·  " : "") + (root.volumeLabel || "—")
              + (root.inputSel ? "  ·  " + root.inputSel : "")
              + (root.program ? "  ·  " + root.program : "")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Item {
            id: room
            width: parent.width
            height: 196

            readonly property real pad: 16
            readonly property real trackTop: 52
            readonly property real trackBottom: height - 46
            readonly property real trackLeft: pad + 18
            readonly property real trackRight: width - pad - 18

            function yForLift(n) {
              var span = trackBottom - trackTop - seat.height
              if (span <= 0) return trackTop
              var t = 1 - (Math.max(0, Math.min(5, n)) / 5)
              return trackTop + t * span
            }

            function xForBalance(n) {
              var span = trackRight - trackLeft - seat.width
              if (span <= 0) return Math.max(0, (width - seat.width) / 2)
              var t = (Math.max(-5, Math.min(5, n)) + 5) / 10
              return trackLeft + t * span
            }

            function liftForY(y) {
              var span = trackBottom - trackTop - seat.height
              if (span <= 0) return root.dialogueLift
              var t = (y - trackTop) / span
              return Math.round((1 - Math.max(0, Math.min(1, t))) * 5)
            }

            function balanceForX(x) {
              var span = trackRight - trackLeft - seat.width
              if (span <= 0) return 0
              var t = (x - trackLeft) / span
              return Math.round(Math.max(0, Math.min(1, t)) * 10 - 5)
            }

            function placeSeat() {
              seat.x = xForBalance(root.lrBalance)
              seat.y = yForLift(root.dialogueLift)
            }

            function applySeat(x, y) {
              x = Math.max(-5, Math.min(5, x))
              y = Math.max(0, Math.min(5, y))
              root.lrBalance = x
              root.dialogueLift = y
              placeSeat()
              root.sendRequest({ "op": "seat", "x": x, "y": y })
            }

            onWidthChanged: if (!root.seatBusy) placeSeat()
            onHeightChanged: if (!root.seatBusy) placeSeat()
            Connections {
              target: root
              function onDialogueLiftChanged() {
                if (!root.seatBusy) seat.y = room.yForLift(root.dialogueLift)
              }
              function onLrBalanceChanged() {
                if (!root.seatBusy) seat.x = room.xForBalance(root.lrBalance)
              }
            }

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
              border.width: 2
              border.color: root.foreground
              opacity: 0.85
            }

            Repeater {
              model: 4
              Rectangle {
                x: room.pad + 8
                width: room.width - room.pad * 2 - 16
                height: 1
                y: room.trackTop + index * ((room.trackBottom - room.trackTop) / 3)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              }
            }

            Rectangle {
              id: screen
              anchors.horizontalCenter: parent.horizontalCenter
              y: 10
              width: parent.width * 0.42
              height: 10
              radius: 3
              color: root.online ? root.accent : root.dim
              opacity: 0.9
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              y: 22
              text: "SCREEN"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: ListModel {
                ListElement { sx: 0.18; sy: 0.22; tag: "FL" }
                ListElement { sx: 0.50; sy: 0.16; tag: "C" }
                ListElement { sx: 0.82; sy: 0.22; tag: "FR" }
                ListElement { sx: 0.12; sy: 0.52; tag: "SL" }
                ListElement { sx: 0.88; sy: 0.52; tag: "SR" }
                ListElement { sx: 0.22; sy: 0.82; tag: "SBL" }
                ListElement { sx: 0.78; sy: 0.82; tag: "SBR" }
                ListElement { sx: 0.50; sy: 0.88; tag: "SW" }
              }
              Rectangle {
                required property real sx
                required property real sy
                required property string tag
                width: 10
                height: 10
                radius: 5
                x: sx * room.width - width / 2
                y: sy * room.height - height / 2
                color: root.sevenOn || tag === "C" || tag === "FL" || tag === "FR" ? root.foreground : root.dim
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.top: parent.bottom
                  anchors.topMargin: 2
                  text: tag
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Rectangle {
              id: seat
              width: 44
              height: 28
              x: room.width > 80 ? room.xForBalance(root.lrBalance) : Math.max(0, (room.width - width) / 2)
              y: room.height > 80 ? room.yForLift(root.dialogueLift) : room.trackTop
              radius: 7
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.seatBusy ? 0.95 : 0.72)
              border.width: 1
              border.color: root.foreground

              Rectangle {
                width: parent.width * 0.72
                height: 7
                radius: 3
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 3
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
              }

              MouseArea {
                id: seatDrag
                anchors.fill: parent
                anchors.margins: -10
                drag.target: seat
                drag.axis: Drag.XAndYAxis
                drag.minimumX: room.trackLeft
                drag.maximumX: Math.max(room.trackLeft, room.trackRight - seat.width)
                drag.minimumY: room.trackTop
                drag.maximumY: Math.max(room.trackTop, room.trackBottom - seat.height)
                preventStealing: true
                cursorShape: Qt.SizeAllCursor
                onPressed: root.seatBusy = true
                onCanceled: {
                  root.seatBusy = false
                  room.placeSeat()
                }
                onReleased: {
                  root.seatBusy = false
                  if (room.width < 80) {
                    room.placeSeat()
                    return
                  }
                  room.applySeat(room.balanceForX(seat.x), room.liftForY(seat.y))
                }
              }
            }

          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "7.1  ·  L/R " + (root.lrBalance > 0 ? "+" : "") + root.lrBalance + "  ·  F/R " + root.dialogueLift + "/5"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "straight"; text: "STRT"; tooltipText: "Straight: Decodes audio without DSP processing"; on: root.straightOn; keyWidth: 92 }
            RemoteKey { action: "program-7ch"; text: "7CH"; tooltipText: "7ch Stereo: All-channel stereo for wide sound"; on: root.sevenOn; keyWidth: 92 }
            RemoteKey { action: "pure-direct"; text: "PURE"; tooltipText: "Pure Direct: Bypasses all DSP circuitry for purest hi-fi sound"; on: root.pureOn; keyWidth: 92 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "power-on"; iconText: "󰐥"; text: "ON"; tooltipText: "Power on the receiver"; on: root.online; keyWidth: 92 }
            RemoteKey { action: "power-off"; iconText: "󰤄"; text: "OFF"; tooltipText: "Set receiver to standby"; on: !root.online; keyWidth: 92 }
            RemoteKey { action: "mute"; iconText: root.muted ? "󰝟" : "󰕾"; text: "MUTE"; tooltipText: "Toggle mute"; on: root.muted; keyWidth: 92 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "volume-down"; iconText: "󰕿"; text: "VOL−"; tooltipText: "Volume down 0.5 dB"; keyWidth: 142 }
            RemoteKey { action: "volume-up"; iconText: "󰖀"; text: "VOL+"; tooltipText: "Volume up 0.5 dB"; keyWidth: 142 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "input-hdmi1"; text: "HDMI1"; keyWidth: 56 }
            RemoteKey { action: "input-hdmi2"; text: "HDMI2"; keyWidth: 56 }
            RemoteKey { action: "input-hdmi3"; text: "HDMI3"; keyWidth: 56 }
            RemoteKey { action: "input-hdmi4"; text: "HDMI4"; keyWidth: 56 }
            RemoteKey { action: "input-hdmi5"; text: "HDMI5"; keyWidth: 56 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "scene-1"; text: "SC1"; keyWidth: 68 }
            RemoteKey { action: "scene-2"; text: "SC2"; keyWidth: 68 }
            RemoteKey { action: "scene-3"; text: "SC3"; keyWidth: 68 }
            RemoteKey { action: "scene-4"; text: "SC4"; keyWidth: 68 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)

            Button {
              width: 142
              height: 38
              text: "AUDIO"
              iconText: "󰓃"
              tooltipText: "Tone, Dialogue & DSP audio settings"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.viewMode = "audio"
            }

            Button {
              width: 142
              height: 38
              text: "HOST"
              iconText: "󰒋"
              tooltipText: "Configure receiver IP address and name"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: {
                hostInput.text = root.activeHost
                nameInput.text = root.activeName
                root.viewMode = "devices"
              }
            }
          }

          Text {
            visible: root.processError !== ""
            width: parent.width
            text: root.processError
            textFormat: Text.PlainText
            color: root.accent
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            text: "[A] AUDIO  [D] HOST  [S] STRT  [7] 7CH  [U] PURE"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          visible: root.viewMode === "audio"
          width: parent.width
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "TONE & SUBWOOFER"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ToneRow {
            title: "BASS"
            tooltipInfo: "Bass: 350 Hz shelving EQ (-6.0 dB to +6.0 dB)"
            displayValue: (root.bass || "+0.0") + " dB"
            actionDown: "bass-down"
            actionUp: "bass-up"
            setOp: "set-bass"
          }

          ToneRow {
            title: "TREBLE"
            tooltipInfo: "Treble: 3.5 kHz shelving EQ (-6.0 dB to +6.0 dB)"
            displayValue: (root.treble || "+0.0") + " dB"
            actionDown: "treble-down"
            actionUp: "treble-up"
            setOp: "set-treble"
          }

          ToneRow {
            title: "SUB TRIM"
            tooltipInfo: "Subwoofer Trim: Fine-tunes sub output (-6.0 dB to +6.0 dB)"
            displayValue: (root.subTrim || "+0.0") + " dB"
            actionDown: "subtrim-down"
            actionUp: "subtrim-up"
            setOp: "set-subtrim"
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: lvlHeader.implicitHeight

            Text {
              id: lvlHeader
              anchors.centerIn: parent
              text: "DIALOGUE LEVEL"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: lvlHover
              anchors.fill: parent
              hoverEnabled: true
            }

            PanelToolTip {
              visible: lvlHover.containsMouse
              text: "Boosts vocal midrange frequencies to clarify speech without increasing volume"
              panelForeground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            PillButton { text: "LV 0"; tooltipText: "Dialogue Level Off (standard mix)"; on: root.dialogueLvl === 0; pillWidth: 67; onClicked: root.sendRequest({ "op": "set-dialogue-lvl", "value": 0 }) }
            PillButton { text: "LV 1"; tooltipText: "Dialogue Level 1 (mild vocal boost)"; on: root.dialogueLvl === 1; pillWidth: 67; onClicked: root.sendRequest({ "op": "set-dialogue-lvl", "value": 1 }) }
            PillButton { text: "LV 2"; tooltipText: "Dialogue Level 2 (medium vocal boost)"; on: root.dialogueLvl === 2; pillWidth: 67; onClicked: root.sendRequest({ "op": "set-dialogue-lvl", "value": 2 }) }
            PillButton { text: "LV 3"; tooltipText: "Dialogue Level 3 (maximum vocal boost)"; on: root.dialogueLvl === 3; pillWidth: 67; onClicked: root.sendRequest({ "op": "set-dialogue-lvl", "value": 3 }) }
          }

          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: liftHeader.implicitHeight

            Text {
              id: liftHeader
              anchors.centerIn: parent
              text: "DIALOGUE LIFT"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: liftHover
              anchors.fill: parent
              hoverEnabled: true
            }

            PanelToolTip {
              visible: liftHover.containsMouse
              text: "Uses front presence speakers to raise dialogue vertically toward the screen center"
              panelForeground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(5)
            Repeater {
              model: 6
              PillButton {
                required property int index
                text: String(index)
                tooltipText: index === 0 ? "Dialogue Lift Off (normal height)" : ("Dialogue Lift " + index + "/5 (elevate dialogue)")
                on: root.dialogueLift === index
                pillWidth: 44
                onClicked: {
                  root.dialogueLift = index
                  root.sendRequest({ "op": "set-dialogue-lift", "value": index })
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "DSP & ENHANCEMENT"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "extra-bass-toggle"; text: "EX BASS"; tooltipText: "Extra Bass: Boosts bass for front speakers & sub"; on: root.extraBassOn; keyWidth: 92 }
            RemoteKey { action: "ypao-volume-toggle"; text: "YPAO VOL"; tooltipText: "YPAO Volume: Dynamic loudness curve at low volumes"; on: root.ypaoVolOn; keyWidth: 92 }
            RemoteKey { action: "adaptive-drc-toggle"; text: "A-DRC"; tooltipText: "Adaptive DRC: Compresses dynamic range for night listening"; on: root.adaptDrcOn; keyWidth: 92 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "enhancer-toggle"; text: "ENHANCER"; tooltipText: "Music Enhancer: Regenerates lost harmonics in compressed audio"; on: root.enhancerOn; keyWidth: 142 }
            RemoteKey { action: "cinema3d-toggle"; text: "CINEMA 3D"; tooltipText: "Cinema DSP 3D: Generates 3D height soundfield"; on: root.cinema3dOn; keyWidth: 142 }
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 291
            height: 38
            text: "BACK"
            iconText: "󰁍"
            tooltipText: "Return to remote control"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: root.viewMode = "remote"
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            text: "[B] BACK  [E] EX BASS  [Y] YPAO  [D] DRC  [H] ENH"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          visible: root.viewMode === "devices"
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: hostInput
            width: parent.width
            placeholderText: "192.168.1.2"
            foreground: root.foreground
            accent: root.accent
            onAccepted: root.setHost()
            Keys.onEscapePressed: function(event) {
              root.viewMode = "remote"
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
          TextField {
            id: nameInput
            width: parent.width
            placeholderText: "Optional name"
            foreground: root.foreground
            accent: root.accent
            onAccepted: root.setHost()
            Keys.onEscapePressed: function(event) {
              root.viewMode = "remote"
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)

            Button {
              width: 142
              height: 38
              text: "CANCEL"
              iconText: "󰁍"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.viewMode = "remote"
            }

            Button {
              width: 142
              height: 38
              text: "CONNECT"
              iconText: "󰒋"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.setHost()
            }
          }
        }
      }
    }
  }
}
