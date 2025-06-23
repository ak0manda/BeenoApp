import Cocoa

// expliziter Einstieg: AppDelegate benutzen
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate



// startet Run-Loop
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
