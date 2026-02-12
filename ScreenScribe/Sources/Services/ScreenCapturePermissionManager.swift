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
    private let hasRequestedPermissionKey = "hasRequestedScreenRecordingPermission"
    private let lastPromptDateKey = "lastScreenRecordingPermissionPromptDate"

    /// UserDefaults instance for persistence
    private let defaults = UserDefaults.standard

    /// Timer for periodic permission checking
    private var permissionCheckTimer: Timer?

    /// Polling interval in seconds
    private let pollingInterval: TimeInterval = 2.0

    /// Minimum time interval (in seconds) between showing the system permission dialog
    private let popupCooldownInterval: TimeInterval = 30.0

    /// Timestamp of the last time we showed the system permission dialog
    private var lastPopupTime: Date?

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
        // via requestPermissionAndStartMonitoring()
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

    /// Request permission and start monitoring for changes
    func requestPermissionAndStartMonitoring(userInitiated: Bool = false) async {
        Logger.log(.info, "Starting permission request and monitoring (userInitiated: \(userInitiated))...")

        // Check if user previously had permission verified successfully
        // This is more reliable than just checking onboarding completion
        let hadPermissionBefore = defaults.bool(forKey: verifiedPermissionKey)
        let hasRequestedBefore = defaults.bool(forKey: hasRequestedPermissionKey)

        // First, check via ScreenCaptureKit with retries (more reliable on macOS Sequoia/Tahoe)
        // CGPreflightScreenCaptureAccess can return false even when permission is granted
        // ScreenCaptureKit can also throw errors after restart/cold boot, so we retry with linear backoff
        // Use more attempts and longer delays if user previously had permission (likely still granted)
        let maxAttempts = hadPermissionBefore ? 8 : 5
        let baseDelay = hadPermissionBefore ? 1.5 : 1.0
        let verificationResult = await verifyPermissionViaScreenCaptureKit(maxAttempts: maxAttempts, delaySeconds: baseDelay)

        // If permission verified, we're done
        if verificationResult == .granted {
            Logger.log(.info, "Permission already granted (verified via ScreenCaptureKit with retries)")
            return
        }

        // Also try CGPreflightScreenCaptureAccess as a final check before showing dialog
        // Sometimes it works even when ScreenCaptureKit fails
        if CGPreflightScreenCaptureAccess() {
            Logger.log(.info, "Permission detected via CGPreflightScreenCaptureAccess after ScreenCaptureKit failed")
            hasPermission = true
            defaults.set(true, forKey: verifiedPermissionKey)
            stopPolling()
            return
        }

        let shouldSuppressAutomaticDialog = isModernMacOS
            && !userInitiated
            && (hadPermissionBefore || hasRequestedBefore)

        // Decision logic for showing the system permission dialog:
        // - On modern macOS, avoid repeated automatic dialogs after initial prompt/verification
        // - Allow explicit user-initiated checks to request again when needed
        // - Poll silently when permission checks are likely transient

        switch verificationResult {
        case .granted:
            // Already handled above
            break

        case .denied:
            // User explicitly declined or revoked permission.
            // Clear the verified flag, then either prompt or suppress based on platform/trigger.
            defaults.set(false, forKey: verifiedPermissionKey)

            if shouldSuppressAutomaticDialog {
                Logger.log(.info, "Suppressing automatic system dialog on modern macOS after prior prompt/verification. Polling silently.")
                startPolling()
            } else {
                Logger.log(.info, "Permission was denied/revoked, showing system dialog")
                showSystemDialogIfCooldownExpired(userInitiated: userInitiated)
            }

        case .transientError:
            if hadPermissionBefore || shouldSuppressAutomaticDialog {
                // On modern macOS, permission checks can fail transiently even after prior prompt/verification.
                // Poll silently until the system catches up instead of repeatedly showing dialogs.
                Logger.log(.info, "Transient permission check failure; polling silently instead of showing another automatic dialog.")
                startPolling()
            } else {
                // New user who never had permission, show the dialog
                Logger.log(.info, "New user, showing system dialog")
                showSystemDialogIfCooldownExpired(userInitiated: userInitiated)
            }
        }
    }

    /// Show the system permission dialog if cooldown has expired
    private func showSystemDialogIfCooldownExpired(userInitiated: Bool) {
        let now = Date()
        let shouldShowPopup: Bool
        let persistedPopupTime = defaults.object(forKey: lastPromptDateKey) as? Date
        let latestPopupTime = [lastPopupTime, persistedPopupTime].compactMap { $0 }.max()

        if userInitiated {
            shouldShowPopup = true
        } else if let lastTime = latestPopupTime {
            let timeSinceLastPopup = now.timeIntervalSince(lastTime)
            shouldShowPopup = timeSinceLastPopup >= popupCooldownInterval

            if !shouldShowPopup {
                let remainingCooldown = Int(popupCooldownInterval - timeSinceLastPopup)
                Logger.log(.info, "Skipping system dialog (cooldown active, \(remainingCooldown)s remaining)")
            }
        } else {
            shouldShowPopup = true
        }

        if shouldShowPopup {
            Logger.log(.info, "Showing system permission dialog")
            let result = CGRequestScreenCaptureAccess()
            hasPermission = result
            lastPopupTime = now
            defaults.set(true, forKey: hasRequestedPermissionKey)
            defaults.set(now, forKey: lastPromptDateKey)

            if result {
                defaults.set(true, forKey: verifiedPermissionKey)
                stopPolling()
            }
        }

        // If not granted, start polling
        if !hasPermission {
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
        // Return the cached value (may have been updated by prior ScreenCaptureKit verification)
        return hasPermission
    }

    /// Start polling for permission changes
    private func startPolling() {
        stopPolling()

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
    }

    /// Single poll iteration
    private func pollPermission() async {
        // Try standard API first
        if CGPreflightScreenCaptureAccess() {
            if !hasPermission {
                hasPermission = true
                stopPolling()
                defaults.set(true, forKey: verifiedPermissionKey)
                Logger.log(.info, "Screen capture permission granted (via CGPreflightScreenCaptureAccess)")
            }
            return
        }

        // Fallback: check via ScreenCaptureKit with a couple of attempts
        // On macOS Sequoia/Tahoe, permission detection can be flaky even during polling
        let result = await verifyPermissionViaScreenCaptureKit(maxAttempts: 2, delaySeconds: 0.5)
        if result == .granted {
            Logger.log(.info, "Screen capture permission granted (via ScreenCaptureKit polling)")
        }
    }

    /// Open System Settings to the Screen Recording pane
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
