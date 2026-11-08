//
//  MagSafeLED.swift
//  TempBarApp
//
//  App-side counterpart of LEDHelper.m: unix-socket client for the
//  privileged daemon, persisted user settings, and one-time installer
//  (writes the LaunchDaemon plist via an administrator authorization dialog).
//

import Foundation
import AppKit

// MARK: - Socket client

final class MagSafeLEDClient {
    static let shared = MagSafeLEDClient()
    private let socketPath = "/var/run/tempbar-led.sock"

    /// Sends one JSON request and reads the newline-terminated JSON reply.
    /// Returns nil when the daemon is not reachable (e.g. helper not installed).
    @discardableResult
    private func send(_ payload: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var bytes = Array(socketPath.utf8)
        bytes.append(0)
        guard bytes.count <= 104 else { return nil } // sun_path length on macOS

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for (i, b) in bytes.enumerated() { dest[i] = UInt8(b) }
        }
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // The daemon reads newline-terminated requests — the newline is part
        // of the protocol; without it the helper blocks waiting for more data.
        var payload = body
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { raw -> Int in
            Darwin.send(fd, raw.baseAddress, raw.count, 0)
        }
        guard sent == payload.count else { return nil }

        var received: [UInt8] = []
        var byte: UInt8 = 0
        while received.count < 65536 {
            let n = recv(fd, &byte, 1, 0)
            guard n > 0 else { break }
            if byte == 0x0A { break }
            received.append(byte)
        }
        guard !received.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(received)),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    func status() -> [String: Any]? {
        send(["cmd": "get"])
    }

    /// Polls the socket until it responds or the timeout elapses.
    /// Guards against judging the daemon "lost" while it is still starting
    /// up (launchd spawn latency + throttled respawn can exceed 10 s).
    func waitUpTo(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if status() != nil { return true }
            usleep(500_000)
        }
        return status() != nil
    }

    @discardableResult
    func set(mode: String) -> Bool {
        (send(["cmd": "set", "mode": mode])?["ok"] as? Bool) == true
    }
}

// MARK: - Persisted LED settings (mirror of the daemon config)

enum MagSafeLEDPrefs {
    private static let d = UserDefaults.standard

    static var mode: String {
        get { d.string(forKey: "LEDMode") ?? "system" }
        set { d.set(newValue, forKey: "LEDMode") }
    }

    static func syncToDaemon() {
        MagSafeLEDClient.shared.set(mode: mode)
    }
}

// MARK: - Privileged helper install / uninstall

enum MagSafeLEDInstaller {
    static let daemonLabel = "local.TempBarApp.led-helper"

    static var appBinaryPath: String {
        Bundle.main.executableURL?.path ?? (Bundle.main.bundlePath + "/Contents/MacOS/TempBarApp")
    }

    static var launchDaemonPlistPath: String {
        "/Library/LaunchDaemons/\(daemonLabel).plist"
    }

    static func isPlistInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchDaemonPlistPath)
    }

    static func install() -> Bool {
        runPrivilegedScript(installScript(),
                            prompt: "TempBarApp 需要安装 MagSafe 灯辅助工具(仅需授权一次)")
    }

    private static func runPrivilegedScript(_ script: String, prompt: String) -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempbar-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let scriptURL = dir.appendingPathComponent("helper.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: dir) }

            let escaped = scriptURL.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"bash \(escaped)\" with administrator privileges with prompt \"\(prompt)\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func installScript() -> String {
        let bin = appBinaryPath
        return """
        #!/bin/bash
        set -e
        APP_BIN='\(bin)'
        PLIST='/Library/LaunchDaemons/\(daemonLabel).plist'
        SUPPORT_DIR='/Library/Application Support/TempBarApp'
        mkdir -p "$SUPPORT_DIR"
        cat > "$PLIST" <<XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>$APP_BIN</string>
                <string>--led-helper</string>
            </array>
            <key>KeepAlive</key><true/>
            <key>RunAtLoad</key><true/>
            <key>StandardErrorPath</key><string>$SUPPORT_DIR/helper.log</string>
        </dict>
        </plist>
        XML
        chmod 644 "$PLIST"
        launchctl bootout 'system/\(daemonLabel)' 2>/dev/null || true
        sleep 1
        launchctl bootstrap system "$PLIST" || (sleep 2 && launchctl bootstrap system "$PLIST")
        """
    }
}
