import AppKit

final class StatusBarController {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private var isRecording = false

  private let onStart: () -> Void
  private let onStop: () -> Void
  private let onOpenNotes: () -> Void
  private let onTestCapture: () -> Void
  private let onQuit: () -> Void

  init(
    onStart: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onOpenNotes: @escaping () -> Void,
    onTestCapture: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.onStart = onStart
    self.onStop = onStop
    self.onOpenNotes = onOpenNotes
    self.onTestCapture = onTestCapture
    self.onQuit = onQuit

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "◯"
    statusItem.button?.appearsDisabled = false
    rebuildMenu()
  }

  func setRecording(_ recording: Bool) {
    isRecording = recording
    statusItem.button?.title = recording ? "●" : "◯"
    statusItem.button?.contentTintColor = recording ? NSColor.systemRed : NSColor.labelColor
    rebuildMenu()
  }

  private func rebuildMenu() {
    menu.removeAllItems()

    if isRecording {
      menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopTapped), keyEquivalent: ""))
    } else {
      menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(startTapped), keyEquivalent: ""))
    }

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Test Audio Capture (10s)", action: #selector(testCapture), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Open Notes Folder", action: #selector(openNotes), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Palora", action: #selector(quitTapped), keyEquivalent: "q"))

    for item in menu.items { item.target = self }
    statusItem.menu = menu
  }

  @objc private func startTapped() {
    onStart()
  }

  @objc private func stopTapped() {
    onStop()
  }

  @objc private func openNotes() {
    onOpenNotes()
  }

  @objc private func testCapture() {
    onTestCapture()
  }

  @objc private func quitTapped() {
    onQuit()
  }
}


