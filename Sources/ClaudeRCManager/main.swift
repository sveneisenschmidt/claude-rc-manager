import AppKit

// Wiring grows in later tasks; top-level code is only allowed in main.swift.
// swift test works with this file present: XCTest loads the module without
// executing main (verified by compile probe).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
