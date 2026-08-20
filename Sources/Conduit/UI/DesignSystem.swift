import SwiftUI

/// Semantic colours only.
///
/// The previous palette was four hand-picked RGB values — a dashboard, not a
/// Mac app. These are system colours, which means they track the user's accent
/// and appearance settings, respond to Increase Contrast, and stay legible
/// against vibrancy. Blue-for-read and orange-for-write is Activity Monitor's
/// own disk convention, so the mapping is already familiar.
enum Ink {
    static let read = Color.blue
    static let write = Color.orange
    /// Reserved for things that are actually wrong. If red appears, something
    /// is failing — a capped link, a read error, a refused benchmark.
    static let problem = Color.red
    /// Used sparingly, and only to confirm the absence of a problem.
    static let healthy = Color.green
}

/// The single focal number on a screen.
///
/// Apple screens that report a measurement — Battery, Storage, Screen Time —
/// have exactly one number at full volume and let everything else recede.
/// Rounded design and monospaced digits so the value does not reflow as it
/// changes; `.numericText()` so it rolls rather than snaps.
struct HeroMetric: View {
    var bytesPerSecond: Double
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.rate(bytesPerSecond))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: bytesPerSecond)
                Text(Format.rateUnit(bytesPerSecond))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The read/write split that sits under the hero number.
struct DirectionalRate: View {
    var symbol: String
    var label: String
    var bytesPerSecond: Double
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Format.rateFull(bytesPerSecond))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// A `LabeledContent` row with a monospaced value, which is what most of the
/// grouped form is made of.
struct ValueRow: View {
    var label: String
    var value: String
    var tint: Color?
    var help: String?

    init(_ label: String, _ value: String, tint: Color? = nil, help: String? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
        self.help = help
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        } label: {
            if let help {
                HStack(spacing: 4) {
                    Text(label)
                    InfoButton(help)
                }
            } else {
                Text(label)
            }
        }
    }
}

/// Stand-in for `@State`.
///
/// `@State` is a macro in the macOS 27 SDK, backed by a compiler plugin that
/// ships only with Xcode — see STRATEGY.md §5. `@StateObject` is not a macro
/// and survives a Command Line Tools build, so per-view local state is boxed in
/// one of these and declared with `@StateObject`.
final class Local<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Jargon lives behind these rather than in permanently visible warning text.
/// UASP, bulk-only transport and link ceilings need explaining once, not on
/// every glance.
struct InfoButton: View {
    private let text: String
    @StateObject private var showing = Local(false)

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            showing.value.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing.value, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// Shown only when it is actionable. A warning the user cannot do anything
/// about is just noise that trains them to ignore the real ones.
struct Advice: View {
    enum Level { case warning, problem }

    var level: Level
    var symbol: String
    var message: String

    var body: some View {
        Label {
            Text(message).font(.callout)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(level == .problem ? Ink.problem : Ink.write)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Fills the row with a subtle capacity bar behind free-space and
    /// utilisation figures.
    func capacityBar(fraction: Double, tint: Color) -> some View {
        background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.14))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
