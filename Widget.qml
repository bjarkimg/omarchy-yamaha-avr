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
    straightOn = String(message.straight || "").toLowerCase() === "on"
    pureOn = String(message.pureDirect || "").toLowerCase() === "on"
    sevenOn = String(program).indexOf("7ch") >= 0 && !straightOn
    if (!seatBusy && message.dialogueLift !== undefined && message.dialogueLift !== null && message.dialogueLift !== "")
      dialogueLift = Math.max(0, Math.min(5, Number(message.dialogueLift)))
    if (!seatBusy && message.lrBalance !== undefined && message.lrBalance !== null && message.lrBalance !== "")
      lrBalance = Math.max(-5, Math.min(5, Number(message.lrBalance)))
    if (message.volumeDb !== undefined && message.volumeDb !== null && message.volumeDb !== "")
      volumeLabel = Number(message.volumeDb).toFixed(1) + " dB"
    online = String(message.power || "").toLowerCase() === "on" || Boolean(message.connected)
    if (String(message.status) === "standby") {
      online = false
      statusText = "STANDBY"
    } else if (String(message.status) === "awake") {
      online = true
      statusText = muted ? "MUTED" : (inputSel || "ON")
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
      statusText = "OFFLINE"
      return
    }
    if (message.event !== "result") return
    applyStatus(message)
  }

  function handleTextKey(text) {
    var key = String(text || "").toLowerCase()
    if (viewMode === "devices") {
      if (key === "b" || key === "q") { viewMode = "remote"; return }
      return
    }
    if (key === "p") sendAction("power")
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
    else if (key === "d") viewMode = "devices"
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

  Process {
    id: sessionProcess
    command: [root.remotePath, "--host", root.host, "--name", root.deviceName, "session"]
    stdinEnabled: true
    running: true
    stdout: SplitParser { onRead: function(line) { root.handleSessionLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.processError = String(line || "").trim() } }
    onExited: function() {
      root.sessionReady = false
      root.online = false
      root.statusText = "OFFLINE"
      sessionRestart.restart()
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

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: Style.bar.statusSlot
    implicitHeight: Style.bar.sizeHorizontal

    Text {
      anchors.centerIn: parent
      text: "AV"
      color: root.foreground
      font.family: "sans-serif"
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.popupOpen = !root.popupOpen
      onEntered: if (root.bar) root.bar.showTooltip(root, root.activeName)
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
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              text: root.viewMode === "remote" ? "YAMAHA AVR" : "RECEIVER HOST"
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
                ListElement { sx: 0.22; sy: 0.84; tag: "SBL" }
                ListElement { sx: 0.78; sy: 0.84; tag: "SBR" }
                ListElement { sx: 0.50; sy: 0.90; tag: "SW" }
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

            Text {
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 8
              text: "7.1  ·  L/R " + (root.lrBalance > 0 ? "+" : "") + root.lrBalance + "  ·  F/R " + root.dialogueLift + "/5"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "straight"; text: "STRT"; on: root.straightOn; keyWidth: 92 }
            RemoteKey { action: "program-7ch"; text: "7CH"; on: root.sevenOn; keyWidth: 92 }
            RemoteKey { action: "pure-direct"; text: "PURE"; on: root.pureOn; keyWidth: 92 }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "power"; text: "PWR" }
            RemoteKey { action: "mute"; text: "MUTE" }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            RemoteKey { action: "volume-down"; text: "VOL-" }
            RemoteKey { action: "volume-up"; text: "VOL+" }
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

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 291
            height: 38
            text: "HOST"
            iconText: "󰒋"
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

          Text {
            visible: root.processError !== ""
            width: parent.width
            text: root.processError
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
            text: "[S] STRAIGHT  [7] 7CH  [U] PURE  ·  drag the seat"
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
          }
          TextField {
            id: nameInput
            width: parent.width
            placeholderText: "Optional name"
            foreground: root.foreground
            accent: root.accent
            onAccepted: root.setHost()
          }
          Button {
            width: parent.width
            height: 38
            text: "CONNECT"
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
