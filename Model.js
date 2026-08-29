var HELPER_PYTHON = "/home/arrow/.local/share/mouse-rgb/venv/bin/python"
var HELPER_SCRIPT = "/home/arrow/.local/share/mouse-rgb/mouse_rgb.py"

function clampInt(v, min, max) {
  var n = Math.round(Number(v))
  if (isNaN(n)) return min
  return Math.max(min, Math.min(max, n))
}

// Manual HSV<->RGB so this stays a portable pure-JS module with no Qt.*
// dependency (it is unit-testable with plain node that way).
function hsvToHex(h, s, v) {
  h = ((Number(h) % 360) + 360) % 360
  s = Math.max(0, Math.min(1, Number(s)))
  v = Math.max(0, Math.min(1, Number(v)))
  var c = v * s
  var x = c * (1 - Math.abs((h / 60) % 2 - 1))
  var m = v - c
  var r = 0, g = 0, b = 0
  if (h < 60) { r = c; g = x; b = 0 }
  else if (h < 120) { r = x; g = c; b = 0 }
  else if (h < 180) { r = 0; g = c; b = x }
  else if (h < 240) { r = 0; g = x; b = c }
  else if (h < 300) { r = x; g = 0; b = c }
  else { r = c; g = 0; b = x }

  function toHex(n) {
    var v255 = Math.round((n + m) * 255)
    var s16 = v255.toString(16).toUpperCase()
    return s16.length === 1 ? "0" + s16 : s16
  }
  return toHex(r) + toHex(g) + toHex(b)
}

function hsvFromHex(hex) {
  hex = String(hex || "").replace("#", "")
  if (hex.length !== 6) return { h: 0, s: 1, v: 1 }
  var r = parseInt(hex.substr(0, 2), 16) / 255
  var g = parseInt(hex.substr(2, 2), 16) / 255
  var b = parseInt(hex.substr(4, 2), 16) / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var d = max - min
  var h = 0
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h *= 60
    if (h < 0) h += 360
  }
  return { h: h, s: max === 0 ? 0 : d / max, v: max }
}

function isValidHex(hex) {
  return /^[0-9a-fA-F]{6}$/.test(String(hex || ""))
}

// How many color slots a mode actually accepts. Driven by what the hardware
// (or, for software effects, our own animator) can use -- see the notes in
// mouse_rgb.py for which OpenRGB modes carry a color at all.
function colorCount(mode, perLed) {
  if (mode === "solid") return perLed ? 3 : 1
  if (mode === "static" || mode === "breathing") return 1
  if (mode === "dual_breathing") return 2
  return 0
}

function slotLabels(mode, perLed) {
  if (mode === "solid" && perLed) return ["Left", "Center", "Right"]
  if (mode === "dual_breathing") return ["From", "To"]
  return ["Color"]
}

function applyArgs(stateJson) {
  return [HELPER_PYTHON, HELPER_SCRIPT, "apply", stateJson]
}

function statusArgs() {
  return [HELPER_PYTHON, HELPER_SCRIPT, "status"]
}

function dpiArgs(value) {
  return [HELPER_PYTHON, HELPER_SCRIPT, "dpi", String(value)]
}

function rateArgs(value) {
  return [HELPER_PYTHON, HELPER_SCRIPT, "rate", String(value)]
}

function parseStatus(text) {
  try {
    var parsed = JSON.parse(String(text || "").trim())
    return (parsed && typeof parsed === "object") ? parsed : null
  } catch (e) {
    return null
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    clampInt: clampInt,
    hsvToHex: hsvToHex,
    hsvFromHex: hsvFromHex,
    isValidHex: isValidHex,
    colorCount: colorCount,
    slotLabels: slotLabels,
    applyArgs: applyArgs,
    statusArgs: statusArgs,
    dpiArgs: dpiArgs,
    rateArgs: rateArgs,
    parseStatus: parseStatus
  }
}
