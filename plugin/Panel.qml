import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar widget for the Logitech G203 Lightsync.
//
// All device access goes through ~/.local/share/mouse-rgb/mouse_rgb.py, which
// speaks OpenRGB's SDK protocol instead of the `openrgb` CLI (the CLI mangles
// speed via an unsigned underflow and refuses mode colors outright -- see that
// file for the details) and serializes RGB against ratbagd's DPI traffic,
// which the mouse cannot service concurrently.
Panel {
  id: root
  moduleName: "arrow.mouse-rgb"
  ipcTarget: "arrow.mouse-rgb"

  readonly property string mouseGlyph: "󰍽"
  readonly property string mouseOffGlyph: "󰍾"

  readonly property var modeList: [
    { id: "off",            label: "Off" },
    { id: "solid",          label: "Solid" },
    { id: "static",         label: "Static" },
    { id: "breathing",      label: "Breathing" },
    { id: "cycle",          label: "Cycle" },
    { id: "wave",           label: "Wave" },
    { id: "colormix",       label: "Colormix" },
    { id: "dual_breathing", label: "2-Color" },
    { id: "rainbow",        label: "Rainbow" }
  ]

  readonly property var presetColors: ["FF3B30", "FF9500", "FFD60A", "34C759", "00E5FF", "2979FF", "AF52DE", "FF2D95", "FFFFFF"]
  readonly property var dpiStops: [400, 800, 1200, 1600, 2000, 3200, 4000, 5500, 8000]
  readonly property var rateList: [125, 250, 500, 1000]

  property bool connected: false
  property string deviceLabel: ""
  property bool dpiAvailable: false

  property string mode: "solid"
  property string lastActiveMode: "solid"
  property var colors: ["AF52DE", "00E5FF", "FFD60A"]
  property bool perLed: false
  property int selectedSlot: 0
  property int speed: 50
  property int brightness: 100
  property int direction: 0
  property int dpi: 800
  property int rate: 1000

  property bool applyQueued: false

  readonly property int slotCount: Model.colorCount(mode, perLed)
  readonly property var slotLabels: Model.slotLabels(mode, perLed)
  readonly property bool showColor: slotCount > 0
  readonly property bool showPerLed: mode === "solid"
  readonly property bool showBrightness: mode !== "off"
  readonly property bool showSpeed: ["breathing", "cycle", "wave", "colormix", "dual_breathing", "rainbow"].indexOf(mode) >= 0
  readonly property bool showDirection: mode === "wave"

  readonly property string activeColor: colors[Math.min(selectedSlot, colors.length - 1)] || "FFFFFF"
  readonly property var activeHsv: Model.hsvFromHex(activeColor)

  function modeLabel(id) {
    for (var i = 0; i < modeList.length; i++)
      if (modeList[i].id === id) return modeList[i].label
    return id
  }

  function setMode(id) {
    root.mode = id
    if (id !== "off") root.lastActiveMode = id
    if (root.selectedSlot >= Model.colorCount(id, root.perLed)) root.selectedSlot = 0
    applyDebounce.stop()
    applyNow()
  }

  function toggleOff() {
    setMode(root.mode === "off" ? root.lastActiveMode : "off")
  }

  function setPerLed(value) {
    root.perLed = value
    if (root.selectedSlot >= Model.colorCount(root.mode, value)) root.selectedSlot = 0
    applyDebounce.stop()
    applyNow()
  }

  // Colors are stored fully bright (HSV value = 1); dimming is the separate
  // brightness control, applied device-side. That keeps hue/saturation
  // recoverable from the stored hex no matter how dim the LEDs are set.
  function setSlotColor(hex, immediate) {
    var next = colors.slice()
    next[Math.min(selectedSlot, next.length - 1)] = String(hex).toUpperCase()
    root.colors = next
    if (immediate) { applyDebounce.stop(); applyNow() }
    else applyDebounce.restart()
  }

  function setHue(h, immediate) {
    setSlotColor(Model.hsvToHex(h, Math.max(0.01, activeHsv.s), 1), immediate)
  }

  function setSaturation(s, immediate) {
    setSlotColor(Model.hsvToHex(activeHsv.h, s, 1), immediate)
  }

  function setSpeed(v, immediate) {
    root.speed = Model.clampInt(v, 0, 100)
    if (immediate) { applyDebounce.stop(); applyNow() }
    else applyDebounce.restart()
  }

  function setBrightness(v, immediate) {
    root.brightness = Model.clampInt(v, 0, 100)
    if (immediate) { applyDebounce.stop(); applyNow() }
    else applyDebounce.restart()
  }

  function setDirection(v) {
    root.direction = v
    applyDebounce.stop()
    applyNow()
  }

  function applyNow() {
    if (applyProc.running) { root.applyQueued = true; return }
    root.applyQueued = false
    applyProc.command = Model.applyArgs(JSON.stringify({
      mode: root.mode,
      colors: root.colors,
      perLed: root.perLed,
      speed: root.speed,
      brightness: root.brightness,
      direction: root.direction
    }))
    applyProc.running = true
  }

  function setDpiIndex(idx, immediate) {
    root.dpi = root.dpiStops[Math.round(idx)]
    if (immediate) { dpiDebounce.stop(); applyDpi() }
    else dpiDebounce.restart()
  }

  function applyDpi() {
    if (!root.dpiAvailable || dpiProc.running) return
    dpiProc.command = Model.dpiArgs(root.dpi)
    dpiProc.running = true
  }

  function setRate(value) {
    root.rate = value
    if (!root.dpiAvailable || rateProc.running) return
    rateProc.command = Model.rateArgs(value)
    rateProc.running = true
  }

  function nearestDpiIndex(value) {
    var best = 0, bestDist = 1e9
    for (var i = 0; i < dpiStops.length; i++) {
      var d = Math.abs(dpiStops[i] - value)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  property bool stateAdopted: false

  function handleStatus(text) {
    var info = Model.parseStatus(text)
    if (!info) { root.connected = false; return }
    root.connected = !!info.connected
    root.deviceLabel = info.device || ""
    root.dpiAvailable = !!info.dpiAvailable
    // Only adopt hardware values while the user isn't mid-drag, so a poll
    // landing during interaction can't snap the knob back.
    if (info.dpi > 0 && !dpiSlider.dragging) root.dpi = info.dpi
    if (info.rate > 0) root.rate = info.rate

    // Sync to the persisted settings once, on first successful status, so the
    // panel opens reflecting the device instead of its own defaults. Later
    // polls must not do this or they would fight the user's edits.
    if (root.stateAdopted) return
    root.stateAdopted = true
    if (info.mode) {
      root.mode = info.mode
      if (info.mode !== "off") root.lastActiveMode = info.mode
    }
    if (info.colors && info.colors.length === 3) root.colors = info.colors
    root.perLed = !!info.perLed
    if (info.speed !== undefined) root.speed = info.speed
    if (info.brightness !== undefined) root.brightness = info.brightness
    if (info.direction !== undefined) root.direction = info.direction
    if (root.selectedSlot >= root.slotCount) root.selectedSlot = 0
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: applyDebounce
    interval: 120
    repeat: false
    onTriggered: root.applyNow()
  }

  Timer {
    id: dpiDebounce
    interval: 200
    repeat: false
    onTriggered: root.applyDpi()
  }

  Process {
    id: statusProc
    command: Model.statusArgs()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleStatus(text)
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && root.applyQueued) root.applyNow()
  }

  Process {
    id: dpiProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: rateProc
    stdout: StdioCollector { waitForEnd: true }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.mode === "off" ? root.mouseOffGlyph : root.mouseGlyph
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleOff()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            Text {
              id: heroIcon
              text: root.mode === "off" ? root.mouseOffGlyph : root.mouseGlyph
              color: root.mode === "off" ? root.bar.foreground : "#" + root.activeColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.mode === "off" ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Behavior on color { ColorAnimation { duration: 160 } }
            }

            ToggleSwitch {
              id: powerSwitch
              checked: root.mode !== "off"
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleOff()
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Mouse RGB"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.modeLabel(root.mode).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Mode ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MODE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Grid {
              id: modeGrid
              width: parent.width
              columns: 3
              spacing: Style.spacing.xs

              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.modeList

                Button {
                  required property var modelData
                  width: modeGrid.cellWidth
                  text: modelData.label
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.mode === modelData.id
                  onClicked: root.setMode(modelData.id)
                }
              }
            }
          }

          // ---------- Per-LED ----------
          Toggle {
            width: parent.width
            visible: root.showPerLed
            label: "Per-LED colors"
            description: "Address left, center and right separately"
            checked: root.perLed
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.setPerLed(!root.perLed)
          }

          // ---------- Color ----------
          PanelSeparator {
            visible: root.showColor
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.showColor

            Item {
              width: parent.width
              implicitHeight: Math.max(colorHeader.implicitHeight, hexField.implicitHeight)

              PanelSectionHeader {
                id: colorHeader
                text: root.slotCount > 1
                  ? (root.slotLabels[root.selectedSlot] || "Color").toUpperCase()
                  : "COLOR"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                id: hexField
                width: Style.space(84)
                horizontalAlignment: Text.AlignHCenter
                maximumLength: 6
                validator: RegularExpressionValidator { regularExpression: /[0-9A-Fa-f]{0,6}/ }
                foreground: root.bar.foreground
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                Component.onCompleted: text = root.activeColor
                onAccepted: {
                  if (Model.isValidHex(text)) root.setSlotColor(text, true)
                  else text = root.activeColor
                }
              }
            }

            Connections {
              target: root
              function onActiveColorChanged() {
                if (!hexField.activeFocus) hexField.text = root.activeColor
              }
            }

            // Slot chips — only meaningful once a mode carries more than one
            // color, so a single-color mode doesn't grow a pointless row.
            Row {
              width: parent.width
              spacing: Style.spacing.xs
              visible: root.slotCount > 1

              Repeater {
                model: root.slotCount

                Button {
                  required property int index
                  width: (panelColumn.width - Style.spacing.xs * (root.slotCount - 1)) / root.slotCount
                  // slotCount and slotLabels are separate bindings, so on a
                  // mode switch that shrinks the slot list one can update a
                  // beat before the other; fall back rather than bind undefined.
                  text: root.slotLabels[index] || ""
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.selectedSlot === index
                  onClicked: root.selectedSlot = index

                  Rectangle {
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: "#" + (root.colors[index] || "FFFFFF")
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.presetColors

                Rectangle {
                  required property string modelData
                  width: Style.space(24)
                  height: Style.space(24)
                  radius: width / 2
                  color: "#" + modelData
                  border.width: root.activeColor === modelData ? Style.space(3) : Style.space(1)
                  border.color: root.activeColor === modelData ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.8)

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setSlotColor(parent.modelData, true)
                  }
                }
              }
            }

            GradientSlider {
              id: hueSlider
              width: parent.width
              value: root.activeHsv.h
              maximum: 359
              trackGradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0;   color: "#FF0000" }
                GradientStop { position: 0.166; color: "#FFFF00" }
                GradientStop { position: 0.333; color: "#00FF00" }
                GradientStop { position: 0.5;   color: "#00FFFF" }
                GradientStop { position: 0.666; color: "#0000FF" }
                GradientStop { position: 0.833; color: "#FF00FF" }
                GradientStop { position: 1.0;   color: "#FF0000" }
              }
              knobColor: "#" + Model.hsvToHex(liveValue, 1, 1)
              onMoved: function(v) { root.setHue(v, false) }
              onCommitted: function(v) { root.setHue(v, true) }
            }

            GradientSlider {
              id: satSlider
              width: parent.width
              value: root.activeHsv.s * 100
              maximum: 100
              trackGradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#FFFFFF" }
                GradientStop { position: 1.0; color: "#" + Model.hsvToHex(root.activeHsv.h, 1, 1) }
              }
              knobColor: "#" + Model.hsvToHex(root.activeHsv.h, liveValue / 100, 1)
              onMoved: function(v) { root.setSaturation(v / 100, false) }
              onCommitted: function(v) { root.setSaturation(v / 100, true) }
            }
          }

          // ---------- Direction ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.showDirection

            PanelSectionHeader {
              text: "DIRECTION"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Grid {
              id: dirGrid
              width: parent.width
              columns: 2
              spacing: Style.spacing.xs
              readonly property real cellWidth: (width - spacing) / 2

              Button {
                width: dirGrid.cellWidth
                text: "Left to right"
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.direction === 0
                onClicked: root.setDirection(0)
              }

              Button {
                width: dirGrid.cellWidth
                text: "Right to left"
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.direction === 1
                onClicked: root.setDirection(1)
              }
            }
          }

          // ---------- Speed ----------
          PanelSeparator {
            visible: root.showSpeed
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.showSpeed

            LabeledValue {
              width: parent.width
              label: "SPEED"
              value: Math.round(speedSlider.dragging ? speedSlider.liveValue : root.speed) + "%"
            }

            PanelSlider {
              id: speedSlider
              bar: root.bar
              width: parent.width
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.speed
              onMoved: function(v) { root.setSpeed(v, false) }
              onReleased: function(v) { root.setSpeed(v, true) }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.showBrightness
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.showBrightness

            LabeledValue {
              width: parent.width
              label: "BRIGHTNESS"
              value: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightness) + "%"
            }

            PanelSlider {
              id: brightnessSlider
              bar: root.bar
              width: parent.width
              minimum: 1
              maximum: 100
              step: 5
              integer: true
              value: root.brightness
              onMoved: function(v) { root.setBrightness(v, false) }
              onReleased: function(v) { root.setBrightness(v, true) }
            }
          }

          // ---------- DPI ----------
          PanelSeparator {
            visible: root.dpiAvailable
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.dpiAvailable

            LabeledValue {
              width: parent.width
              label: "DPI"
              value: String(dpiSlider.dragging ? root.dpiStops[Math.round(dpiSlider.liveValue)] : root.dpi)
            }

            PanelSlider {
              id: dpiSlider
              bar: root.bar
              width: parent.width
              minimum: 0
              maximum: root.dpiStops.length - 1
              step: 1
              integer: true
              tickCount: root.dpiStops.length
              value: root.nearestDpiIndex(root.dpi)
              onMoved: function(v) { root.setDpiIndex(v, false) }
              onReleased: function(v) { root.setDpiIndex(v, true) }
            }
          }

          // ---------- Polling rate ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.dpiAvailable

            PanelSectionHeader {
              text: "POLLING RATE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Grid {
              id: rateGrid
              width: parent.width
              columns: root.rateList.length
              spacing: Style.spacing.xs
              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.rateList

                Button {
                  required property int modelData
                  width: rateGrid.cellWidth
                  text: modelData + "Hz"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.rate === modelData
                  onClicked: root.setRate(modelData)
                }
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator { foreground: root.bar.foreground }

          Text {
            width: parent.width
            text: root.connected ? root.deviceLabel : "OpenRGB server unavailable"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // Section header with a right-aligned readout — the label/value pairing
  // repeats for every slider, so it lives in one place.
  component LabeledValue: Item {
    required property string label
    required property string value
    implicitHeight: Math.max(lv_label.implicitHeight, lv_value.implicitHeight)

    PanelSectionHeader {
      id: lv_label
      text: parent.label
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: lv_value
      text: parent.value
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Slider whose track paints an arbitrary gradient — used for hue and
  // saturation, where the track itself has to show what you're choosing.
  // PanelSlider can't do this: its track is a single flat fill.
  component GradientSlider: Item {
    id: gs
    property real value: 0
    property real maximum: 100
    // Passed in declaratively by the caller. Building the stops in JS and
    // assigning them here does not survive — the created GradientStop objects
    // are parentless and get collected, leaving an unpainted track.
    property Gradient trackGradient: null
    property color knobColor: "#FFFFFF"
    property real liveValue: value
    property bool dragging: false
    property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
    property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))

    signal moved(real value)
    signal committed(real value)

    onValueChanged: if (!dragging) liveValue = value

    implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

    readonly property real progress: maximum > 0 ? Math.max(0, Math.min(1, liveValue / maximum)) : 0
    readonly property bool _hot: gsMouse.containsMouse || gs.dragging

    Rectangle {
      id: gsTrack
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      height: gs.trackHeight
      radius: height / 2
      gradient: gs.trackGradient
    }

    Rectangle {
      width: gs.knobSize
      height: gs.knobSize
      radius: width / 2
      color: gs.knobColor
      border.color: root.bar ? root.bar.background : "#101315"
      border.width: Math.max(1, Style.space(2))
      anchors.verticalCenter: gsTrack.verticalCenter
      x: Math.max(0, Math.min(gsTrack.width - width, gsTrack.width * gs.progress - width / 2))
      scale: gs._hot ? 1.15 : 1.0

      Behavior on x {
        enabled: !gs.dragging
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
      Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      id: gsMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      function valueFromX(x) {
        var clamped = Math.max(0, Math.min(gsTrack.width, x))
        return Math.max(0, Math.min(gs.maximum, (clamped / gsTrack.width) * gs.maximum))
      }
      onPressed: function(mouse) {
        gs.dragging = true
        gs.liveValue = valueFromX(mouse.x)
        gs.moved(gs.liveValue)
      }
      onPositionChanged: function(mouse) {
        if (!gs.dragging) return
        gs.liveValue = valueFromX(mouse.x)
        gs.moved(gs.liveValue)
      }
      onReleased: function(mouse) {
        gs.dragging = false
        gs.committed(gs.liveValue)
      }
    }
  }
}
