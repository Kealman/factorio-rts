// Real mouse and keyboard input into the Factorio GUI window (Phase 5 M2 QA round 1; tools/gui-drive.sh compiles and
// runs it for GUI probes that need the engine's own input path, e.g. tools/probes/m2_qafix_gui.lua).
// The process that runs it needs the macOS Accessibility permission.
// fdrive win                                  -> "<window id> <x> <y> <w> <h>" of the Factorio window (points)
// fdrive move X Y | click X Y | rclick X Y    game-area coordinates (the title bar is the window height - 800)
// fdrive key <virtual keycode>                e.g. 12 = Q, 3 = F
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
guard args.count >= 2, let (wid, r) = factorioWindow() else { print("no window"); exit(1) }
let titleBar = r.height - 800
func pt(_ x: String, _ y: String) -> CGPoint {
  return CGPoint(x: r.origin.x + CGFloat(Double(x)!), y: r.origin.y + titleBar + CGFloat(Double(y)!))
}
let src = CGEventSource(stateID: .hidSystemState)
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
  CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(120000)
  CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: p,
          mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
  usleep(80000)
  CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: p,
          mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
case "key":
  let code = CGKeyCode(Int(args[2])!)
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
  usleep(60000)
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
default:
  print("unknown command"); exit(2)
}
