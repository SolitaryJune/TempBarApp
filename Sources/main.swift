import AppKit

// Privileged LED helper modes (launchd runs this same binary as root with
// --led-helper; --led-once applies one state and exits). Must branch before
// any AppKit initialization happens below.
if CommandLine.arguments.contains("--led-helper") || CommandLine.arguments.contains("--led-once") {
    exit(LEDHelperMain(CommandLine.argc, CommandLine.unsafeArgv))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
