import AppKit
import Foundation
import os
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "app.audiochrome.Audiochrome", category: "EQStatusNotifier")

/// Local macOS notifications for which EQ profile is mapped to the current output.
@MainActor
public final class EQStatusNotifier: NSObject {
    public static let shared = EQStatusNotifier()

    private static let notificationID = "app.audiochrome.eq-status"
    /// Banner on-screen time; then remove from Notification Center.
    private static let clearAfter: TimeInterval = 5.5

    private let center = UNUserNotificationCenter.current()
    private var didConfigure = false
    private var clearWorkItem: DispatchWorkItem?
    /// Clicking the banner. Set by the app (opens the menu panel).
    public var onSelect: (() -> Void)?

    private override init() {
        super.init()
    }

    /// Call once at launch (before posting). Sets the foreground presentation delegate.
    public func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        center.delegate = self
        log.info("Configured UNUserNotificationCenter (bundle \(Bundle.main.bundleIdentifier ?? "nil", privacy: .public))")
    }

    /// Removes any delivered / pending EQ status notification.
    public func clearActiveEQ() {
        configure()
        clearWorkItem?.cancel()
        clearWorkItem = nil
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        log.info("Cleared EQ status notification")
    }

    /// Requests alert permission if still undetermined, then posts the EQ status banner.
    public func notifyActiveEQ(
        outputName: String,
        profileDisplayName: String,
        folderName: String,
        colorHex: String,
        effectsLabel: String = ""
    ) {
        configure()

        let payload = Payload(
            outputName: outputName,
            profileDisplayName: profileDisplayName,
            colorHex: colorHex,
            effectsLabel: effectsLabel
        )
        _ = folderName
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .notDetermined:
                    self.requestAuthorizationAndPost(payload)
                case .authorized, .provisional:
                    self.post(payload)
                case .denied:
                    log.error("Notification permission denied — enable Audiochrome in System Settings → Notifications")
                @unknown default:
                    log.error("Unknown notification authorization status")
                }
            }
        }
    }

    public func requestAuthorizationIfNeeded() {
        configure()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in
                self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        log.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
                    } else {
                        log.info("Notification auth granted=\(granted)")
                    }
                }
            }
        }
    }

    /// Call after launch auth has had a moment — avoids racing the first banner.
    public func notifyActiveEQAfterLaunch(
        outputName: String,
        profileDisplayName: String,
        folderName: String,
        colorHex: String,
        effectsLabel: String = ""
    ) {
        configure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.notifyActiveEQ(
                outputName: outputName,
                profileDisplayName: profileDisplayName,
                folderName: folderName,
                colorHex: colorHex,
                effectsLabel: effectsLabel
            )
        }
    }

    private struct Payload {
        let outputName: String
        let profileDisplayName: String
        let colorHex: String
        let effectsLabel: String
    }

    private func requestAuthorizationAndPost(_ payload: Payload) {
        NSApp.activate(ignoringOtherApps: true)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                log.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
            }
            log.info("Notification auth granted=\(granted)")
            guard granted else { return }
            Task { @MainActor in
                self?.post(payload)
            }
        }
    }

    private func post(_ payload: Payload) {
        let content = UNMutableNotificationContent()
        let trimmedEffects = payload.effectsLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEffects.isEmpty {
            content.title = payload.profileDisplayName
        } else {
            content.title = "\(payload.profileDisplayName) · \(trimmedEffects)"
        }
        content.body = payload.outputName
        if let attachment = makeProfileMarkAttachment(hex: payload.colorHex) {
            content.attachments = [attachment]
        }

        // One EQ status notification at a time — drop the previous before posting.
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])

        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                log.error("Failed to post notification: \(error.localizedDescription, privacy: .public)")
                return
            }
            log.info("Posted EQ status notification")
            Task { @MainActor in
                self?.scheduleClear()
            }
        }
    }

    private func scheduleClear() {
        clearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearActiveEQ()
        }
        clearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearAfter, execute: work)
    }

    /// Profile-color plate + rest bars for the trailing thumbnail.
    private func makeProfileMarkAttachment(hex: String) -> UNNotificationAttachment? {
        guard let png = renderProfileMarkPNG(hex: hex) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiochromeNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let url = dir.appendingPathComponent("profile-\(cleaned).png")
        do {
            try png.write(to: url, options: .atomic)
            return try UNNotificationAttachment(
                identifier: "profile-mark",
                url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
        } catch {
            log.error("Profile mark attachment failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func renderProfileMarkPNG(hex: String) -> Data? {
        let pixels = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.shouldAntialias = true

        let bounds = NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
        NSColor.clear.setFill()
        bounds.fill()
        ProfileColorPalette.nsColor(hex, role: .ui, dark: false).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ProfileColorPalette.barInk(for: hex).setFill()
        for rect in MenuBarBarsMark.listBarFrames(center: center, size: CGFloat(pixels)) {
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width / 2,
                yRadius: rect.width / 2
            ).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension EQStatusNotifier: UNUserNotificationCenterDelegate {
    /// Banner only — skip `.list` so it doesn’t linger in Notification Center history.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onSelect?()
            }
            completionHandler()
        }
    }
}
