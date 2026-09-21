import Foundation

// Headless mode for tests and key setup; otherwise start the SwiftUI app (menu bar agent + hotkey).
if CLI.runIfRequested() { exit(0) }
ArmadaApp.main()
