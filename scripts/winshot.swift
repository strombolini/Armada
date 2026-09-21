import Cocoa
// Usage: swift winshot.swift "Armada" out.png  — captures the frontmost window of the named app.
let app = CommandLine.arguments[1], out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
guard let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == app && (($0[kCGWindowLayer as String] as? Int) ?? 1) <= 3 }),
      let id = w[kCGWindowNumber as String] as? Int else { print("no window"); exit(1) }
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l", String(id), out]
try! p.run(); p.waitUntilExit(); print("captured window \(id) -> \(out)")
