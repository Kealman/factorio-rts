// Real mouse and keyboard input into the Factorio GUI window (Phase 5 M2 QA round 1; tools/gui-drive.sh compiles and
// runs it for GUI probes that need the engine's own input path, e.g. tools/probes/m2_qafix_gui.lua).
// The process that runs it needs the macOS Accessibility permission.
// fdrive win                                  -> "<window id> <x> <y> <w> <h>" of the Factorio window (points)
// fdrive move X Y | click X Y | rclick X Y    game-area coordinates (the title bar is the window height - 800)
// fdrive key <virtual keycode>                e.g. 12 = Q, 3 = F
// 0.1.1 (r2-ux, issue #12: tools/probes/r2_inputs_gui.lua), all backwards compatible:
// fdrive click X Y [MODS] | rclick X Y [MODS]  MODS: shift, ctrl, cmd, alt or a "+" list (shift+ctrl); held around
//                                              the click (key down, flagged mouse events, key up)
// fdrive drag X1 Y1 X2 Y2 [left|right] [MODS] press at 1, dragged events in 12 steps to 2, release at 2
// fdrive key CODE [MODS]                      e.g. key 15 ctrl+shift = Ctrl+Shift+R
// fdrive moddown MODS | modup MODS            press / release modifier keys (shift, ctrl, cmd, alt, a+b) across commands
// fdrive keydown CODE | keyup CODE            hold a key across other commands (e.g. D pans while clicking)
// fdrive hold CODE MS [click|rclick X Y]     a held key with auto-repeat for MS milliseconds (WASD camera pan),
//                                              optionally a click half way through
// fdrive dtap CODE                            a double tap (two presses 120 ms apart)
// fdrive wheel N                              N lines of the scroll wheel at the pointer (positive: up, zoom in)
// fdrive sleep MS                             wait (a pause between two commands logged in the same tick)
// A plain "move" is not always seen by the game (a click is: it moves the pointer before the press).
import Foundation
import CoreGraphics

func factorioWindow() -> (Int, CGRect)? {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] else { return nil }
  for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if owner.lowercased().contains("factorio") && layer == 0 && name.contains("Factorio") {
      let b = w[kCGWindowBounds as String] as! [String: Any]
      let r = CGRect(x: b["X"] as! CGFloat, y: b["Y"] as! CGFloat, width: b["Width"] as! CGFloat,
                     height: b["Height"] as! CGFloat)
      return (w[kCGWindowNumber as String] as! Int, r)
    }
  }
  return nil
}

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "sleep" {
  usleep(UInt32(max(0, Int(args[2]) ?? 0)) * 1000)
  exit(0)
}
guard args.count >= 2, let (wid, r) = factorioWindow() else { print("no window"); exit(1) }
// The game area is 800 points high unless the window was opened with RTS_WINDOW; the title bar is the rest.
let areaHeight = CGFloat(Double(ProcessInfo.processInfo.environment["RTS_AREA_HEIGHT"] ?? "800") ?? 800)
let titleBar = r.height - areaHeight
func pt(_ x: String, _ y: String) -> CGPoint {
  return CGPoint(x: r.origin.x + CGFloat(Double(x)!), y: r.origin.y + titleBar + CGFloat(Double(y)!))
}
let src = CGEventSource(stateID: .hidSystemState)

// Modifiers: "shift", "ctrl", "cmd", "alt", or several joined by "+".
let MOD_KEYS: [String: (CGKeyCode, CGEventFlags)] = [
  "shift": (56, .maskShift), "ctrl": (59, .maskControl), "cmd": (55, .maskCommand), "alt": (58, .maskAlternate),
]
func mods(_ s: String?) -> [(CGKeyCode, CGEventFlags)] {
  guard let s = s, s != "none", s != "" else { return [] }
  return s.split(separator: "+").compactMap { MOD_KEYS[String($0)] }
}
func flags(_ m: [(CGKeyCode, CGEventFlags)]) -> CGEventFlags {
  var f = CGEventFlags()
  for (_, fl) in m { f.insert(fl) }
  return f
}
func modsDown(_ m: [(CGKeyCode, CGEventFlags)]) {
  var f = CGEventFlags()
  for (code, fl) in m {
    f.insert(fl)
    let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    ev?.flags = f
    ev?.post(tap: .cghidEventTap)
    usleep(30000)
  }
}
func modsUp(_ m: [(CGKeyCode, CGEventFlags)]) {
  var f = flags(m)
  for (code, fl) in m.reversed() {
    f.remove(fl)
    let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    ev?.flags = f
    ev?.post(tap: .cghidEventTap)
    usleep(30000)
  }
}
func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, _ f: CGEventFlags) {
  let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
  if !f.isEmpty { ev?.flags = f }
  ev?.post(tap: .cghidEventTap)
}

switch args[1] {
case "win":
  print("\(wid) \(Int(r.origin.x)) \(Int(r.origin.y)) \(Int(r.width)) \(Int(r.height))")
case "move":
  // a warp plus moved events with deltas, in two steps (a lone synthetic move was sometimes ignored)
  let p = pt(args[2], args[3])
  let cur = CGEvent(source: nil)?.location ?? p
  let mid = CGPoint(x: (cur.x + p.x) / 2, y: (cur.y + p.y) / 2)
  for (from, to) in [(cur, mid), (mid, p)] {
    CGWarpMouseCursorPosition(to)
    if let ev = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left) {
      ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(to.x - from.x))
      ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(to.y - from.y))
      ev.post(tap: .cghidEventTap)
    }
    usleep(60000)
  }
case "click", "rclick":
  let p = pt(args[2], args[3])
  let right = args[1] == "rclick"
  let m = mods(args.count > 4 ? args[4] : nil)
  let f = flags(m)
  mouse(.mouseMoved, p, .left, f)
  usleep(120000)
  modsDown(m)
  mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, f)
  usleep(80000)
  mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, f)
  usleep(30000)
  modsUp(m)
case "drag":
  let a = pt(args[2], args[3]), b = pt(args[4], args[5])
  let right = args.count > 6 && args[6] == "right"
  let m = mods(args.count > 7 ? args[7] : nil)
  let f = flags(m)
  let button: CGMouseButton = right ? .right : .left
  mouse(.mouseMoved, a, .left, f)
  usleep(120000)
  modsDown(m)
  mouse(right ? .rightMouseDown : .leftMouseDown, a, button, f)
  usleep(80000)
  let steps = 12
  for i in 1...steps {
    let t = CGFloat(i) / CGFloat(steps)
    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    mouse(right ? .rightMouseDragged : .leftMouseDragged, p, button, f)
    usleep(25000)
  }
  usleep(60000)
  mouse(right ? .rightMouseUp : .leftMouseUp, b, button, f)
  usleep(30000)
  modsUp(m)
case "key":
  let code = CGKeyCode(Int(args[2])!)
  let m = mods(args.count > 3 ? args[3] : nil)
  modsDown(m)
  let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
  down?.flags = flags(m)
  down?.post(tap: .cghidEventTap)
  usleep(60000)
  let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
  up?.flags = flags(m)
  up?.post(tap: .cghidEventTap)
  usleep(30000)
  modsUp(m)
case "hold":
  // a held key: key down, auto-repeat key downs every 50 ms for MS milliseconds, key up (a real held key)
  let code = CGKeyCode(Int(args[2])!)
  let ms = Int(args.count > 3 ? args[3] : "500") ?? 500
  // optional: a click or right click at X Y half way through the hold ("hold 2 1200 rclick 640 280")
  let clickKind = args.count > 6 ? args[4] : ""
  let cp = args.count > 6 ? pt(args[5], args[6]) : CGPoint.zero
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
  var t = 0
  var clicked = clickKind == ""
  while t < ms {
    usleep(50000)
    t += 50
    if let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
      ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
      ev.post(tap: .cghidEventTap)
    }
    if !clicked && t >= ms / 2 {
      clicked = true
      let right = clickKind == "rclick"
      mouse(.mouseMoved, cp, .left, [])
      usleep(40000)
      mouse(right ? .rightMouseDown : .leftMouseDown, cp, right ? .right : .left, [])
      usleep(60000)
      mouse(right ? .rightMouseUp : .leftMouseUp, cp, right ? .right : .left, [])
      t += 100
    }
  }
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
case "dtap":
  // a double tap of one key (two presses 120 ms apart: a control group's camera jump wants both within 20 ticks)
  let code = CGKeyCode(Int(args[2])!)
  for i in 0..<2 {
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(50000)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    if i == 0 { usleep(70000) }
  }
case "keydown", "keyup":
  let code = CGKeyCode(Int(args[2])!)
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: args[1] == "keydown")?.post(tap: .cghidEventTap)
case "moddown", "modup":
  // a modifier key as the hardware sends it: a flagsChanged event (a keyDown of virtual key 56 is not seen as Shift
  // being held by the game itself, only by the clicks that carry its flag)
  var f = CGEventFlags()
  let m = mods(args[2])
  let down = args[1] == "moddown"
  for (code, fl) in (down ? m : m.reversed()) {
    _ = fl
    if down { f.insert(fl) }
    let ev = CGEvent(source: src)
    ev?.type = .flagsChanged
    ev?.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
    ev?.flags = down ? f : CGEventFlags()
    ev?.post(tap: .cghidEventTap)
    usleep(30000)
  }
case "wheel":
  let n = Int32(args[2]) ?? 1
  for _ in 0..<abs(n) {
    CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: n > 0 ? 1 : -1, wheel2: 0,
            wheel3: 0)?.post(tap: .cghidEventTap)
    usleep(40000)
  }
default:
  print("unknown command"); exit(2)
}
