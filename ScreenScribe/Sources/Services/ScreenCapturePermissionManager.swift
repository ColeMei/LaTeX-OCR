import Foundation
import CoreGraphics
import AppKit
import Combine
import ScreenCaptureKit

@MainActor
final class ScreenCapturePermissionManager: ObservableObject {
    static let shared = ScreenCapturePermissionManager()

    /// Published property for reactive UI updates
    @Published private(set) var hasPermission: Bool = false

    /// UserDefaults keys
    private let verifiedPermissionKey = "hasVerifiedScreenRecordingPermission"

    /// UserDefaults instance for persistence
    private let defaults = UserDefaults.standard

    /// Timer for periodic permission checking
    private var permissionCheckTimer: Timer?

    /// Polling interval in seconds
    private let pollingInterval: TimeInterval = 2.0

    /// Prevent overlapping async permission checks while polling
    private var isPollingInProgress = false

    /// On macOS Sequoia/Tahoe and newer, permission checks can be flaky
    private var isModernMacOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    private init() {
        // Only use safe, read-only check on init
        // CGPreflightScreenCaptureAccess does NOT trigger any dialog
        hasPermission = CGPreflightScreenCaptureAccess()
        if hasPermission {
            defaults.set(true, forKey: verifiedPermissionKey)
        }
        // Note: On macOS Sequoia, this may return false even when permission is granted
        // The verification via ScreenCaptureKit will happen when explicitly requested
        // via startMonitoringWithoutPrompt() / requestPermissionInteractively()
    }

    /// Result of permission verification attempt
    private enum VerificationResult {
        case granted
        case denied          // Definitive denial (user explicitly declined/revoked)
        case transientError  // Temporary failure (cold boot timing, system initialization)
    }

    /// Verify permission using ScreenCaptureKit with retry logic
    /// Returns .granted if permission is confirmed, .denied if explicitly declined, .transientError otherwise
    /// On macOS Sequoia/Tahoe, ScreenCaptureKit can throw errors at app launch even when permission is granted
    /// This is a known issue where the system needs time to initialize screen capture subsystems
    private func verifyPermissionViaScreenCaptureKit(maxAttempts: Int = 5, delaySeconds: Double = 1.0) async -> VerificationResult {
        var sawDefinitiveDenial = false

        for attempt in 1...maxAttempts {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasPermission = true
                stopPolling()
                // Track successful permission verification
                defaults.set(true, forKey: verifiedPermissionKey)
                Logger.log(.info, "ScreenCaptureKit permission verified on attempt \(attempt)")
                return .granted
            } catch let error as NSError {
                // Error code -3801 (SCStreamErrorUserDeclined) indicates user explicitly denied permission
                // Error code -3802 (SCStreamErrorFailedToStart) can also indicate permission issues
                // On macOS Sequoia/Tahoe+, -3801 can still be transient, so only trust it on older macOS
                let isDefinitiveDenial = error.code == -3801 && !isModernMacOS

                Logger.log(.info, "ScreenCaptureKit attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code), definitiveDenial: \(isDefinitiveDenial))")

                if isDefinitiveDenial {
                    sawDefinitiveDenial = true
                }

                if attempt < maxAttempts {
                    // Use linear backoff for better handling of slow system initialization
                    let delay = delaySeconds * Double(attempt)
                    Logger.log(.info, "Waiting \(delay)s before retry...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                Logger.log(.info, "ScreenCaptureKit attempt \(attempt)/\(maxAttempts) failed with unexpected error: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    let delay = delaySeconds * Double(attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // If we saw a definitive denial code, report it
        // Otherwise, it's likely a transient error (cold boot timing issue)
        return sawDefinitiveDenial ? .denied : .transientError
    }

    private func markPermissionGranted(source: String) {
        if !hasPermission {
            Logger.log(.info, "Screen capture permission granted (\(source))")
        }
        hasPermission = true
        defaults.set(true, forKey: verifiedPermissionKey)
        stopPolling()
    }

    /// Verify permission and keep watching for external changes without showing system dialogs.
    func startMonitoringWithoutPrompt() async {
        Logger.log(.info, "Starting non-interactive permission monitoring...")

        if checkPermission() {
            return
        }

        // Check if user previously had permission verified successfully
        let hadPermissionBefore = defaults.bool(forKey: verifiedPermissionKey)

        // ScreenCaptureKit can fail transiently at startup, especially on modern macOS.
        // Use slightly stronger retry settings when user had permission before.
        let maxAttempts = hadPermissionBefore ? 8 : 5
        let baseDelay = hadPermissionBefore ? 1.5 : 1.0
        let verificationResult = await verifyPermissionViaScreenCaptureKit(maxAttempts: maxAttempts, delaySeconds: baseDelay)

        if verificationResult == .granted {
            return
        }

        if CGPreflightScreenCaptureAccess() {
            markPermissionGranted(source: "CGPreflightScreenCaptureAccess")
            return
        }

        if verificationResult == .denied {
            defaults.set(false, forKey: verifiedPermissionKey)
        }

        Logger.log(.info, "Permission not currently verified. Polling silently for external changes.")
        startPolling()
    }

    /// Request system permission interactively (user initiated).
    @discardableResult
    func requestPermissionInteractively() async -> Bool {
        Logger.log(.info, "Starting interactive permission request...")

        if checkPermission() {
            return true
        }

        // Fast verification path to avoid prompting when permission is already available
        // but CGPreflightScreenCaptureAccess is temporarily stale/flaky.
        let quickVerification = await verifyPermissionViaScreenCaptureKit(maxAttempts: 2, delaySeconds: 0.25)
        if quickVerification == .granted {
            return true
        }

        if CGPreflightScreenCaptureAccess() {
            markPermissionGranted(source: "CGPreflightScreenCaptureAccess interactive precheck")
            return true
        }

        showSystemDialog()
        if hasPermission {
            return true
        }

        // The system may grant permission asynchronously after the prompt closes.
        let result = await verifyPermissionViaScreenCaptureKit(maxAttempts: 3, delaySeconds: 0.5)
        if result == .granted {
            return true
        }

        if CGPreflightScreenCaptureAccess() {
            markPermissionGranted(source: "CGPreflightScreenCaptureAccess after interactive prompt")
            return true
        }

        startPolling()
        return false
    }

    /// Show the system permission dialog for user-initiated requests.
    private func showSystemDialog() {
        Logger.log(.info, "Showing system permission dialog")
        let result = CGRequestScreenCaptureAccess()

        if result {
            markPermissionGranted(source: "CGRequestScreenCaptureAccess")
        } else {
            hasPermission = false
            defaults.set(false, forKey: verifiedPermissionKey)
            startPolling()
        }
    }

    /// Check permission status (read-only, does not trigger any dialogs)
    func checkPermission() -> Bool {
        // Only use the safe read-only API
        if CGPreflightScreenCaptureAccess() {
            hasPermission = true
            stopPolling()
            // Track successful verification for future cold boot handling
            defaults.set(true, forKey: verifiedPermissionKey)
            return true
        }

        // On modern macOS, CGPreflightScreenCaptureAccess can temporarily return false
        // even while permission is still valid, so avoid clearing granted state here.
        if hasPermission {
            Logger.log(.info, "CGPreflightScreenCaptureAccess returned false while cached permission is true; preserving state and monitoring for changes")
            startPolling()
            return true
        }

        return false
    }

    /// Start polling for permission changes
    private func startPolling() {
        if permissionCheckTimer != nil {
            return
        }

        permissionCheckTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.pollPermission()
            }
        }
    }

    /// Stop polling
    func stopPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        isPollingInProgress = false
    }

    /// Single poll iteration
    private func pollPermission() async {
        guard !isPollingInProgress else {
            Logger.log(.info, "Skipping permission poll because previous poll is still running")
            return
        }
        isPollingInProgress = true
        defer { isPollingInProgress = false }

        // Try standard API first
        if CGPreflightScreenCaptureAccess() {
            markPermissionGranted(source: "CGPreflightScreenCaptureAccess polling")
            return
        }

        // Fallback: check via ScreenCaptureKit with a couple of attempts
        // On macOS Sequoia/Tahoe, permission detection can be flaky even during polling
        let result = await verifyPermissionViaScreenCaptureKit(maxAttempts: 2, delaySeconds: 0.5)
        switch result {
        case .granted:
            Logger.log(.info, "Screen capture permission granted (via ScreenCaptureKit polling)")
        case .denied:
            defaults.set(false, forKey: verifiedPermissionKey)
            hasPermission = false
        case .transientError:
            break
        }
    }

    /// Open System Settings to the Screen Recording pane
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
