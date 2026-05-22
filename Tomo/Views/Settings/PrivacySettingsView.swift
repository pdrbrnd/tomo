import SwiftUI

/// Settings → Privacy: opt out of crash reporting.
///
/// We send Sentry-formatted crash reports + caught errors when something
/// goes wrong; never on every launch, never for analytics. Source paths
/// are scrubbed in `CrashReporter.beforeSend` before the event leaves the
/// device.
struct PrivacySettingsView: View {
    /// @AppStorage observes the underlying key so the toggle reflects
    /// external writes (e.g. another window). Writes go through
    /// `CrashReporter.isEnabled` so Sentry is started/closed in lockstep.
    @AppStorage("tomo.crashReports.disabled") private var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(
                isOn: Binding(
                    get: { !disabled },
                    set: { CrashReporter.isEnabled = $0 }
                )
            ) {
                Text("Send anonymous crash reports")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.vertical, Theme.Spacing.sm)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }

            Text(
                "Crash reports help me fix bugs you'd otherwise have to "
                    + "report by hand. They include only the stack trace and "
                    + "your macOS version — no library contents, no file "
                    + "paths under your home folder, no identifiers."
            )
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Spacing.md)
        }
    }
}
