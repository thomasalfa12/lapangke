import LapangkeCore
import SwiftUI

extension Safety {
    var tint: Color {
        switch self {
        case .regenerable: Brand.ok
        case .costly: Brand.accent
        case .review: Brand.warn
        case .keep: Brand.ink2
        case .managed: .secondary
        }
    }

    /// Latar pastel per label, sama dengan kartu di website.
    var wash: Color {
        switch self {
        case .regenerable: Brand.lime
        case .costly: Brand.sky
        case .review: Brand.peach
        case .keep, .managed: Brand.lavender
        }
    }

    var symbol: String {
        switch self {
        case .regenerable: "checkmark.seal.fill"
        case .costly: "arrow.down.circle.fill"
        case .review: "eye.fill"
        case .keep: "lock.fill"
        case .managed: "gearshape.fill"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safety.tint)
            .background(safety.tint.opacity(0.12), in: Capsule())
            .help(safety.summary)
    }
}

struct Card<Content: View>: View {
    var fill: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct CapacityBar: View {
    let used: Int64
    let total: Int64
    var warning = false

    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(warning
                        ? AnyShapeStyle(LinearGradient(colors: [Brand.bad.opacity(0.8), Brand.bad], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(LinearGradient(colors: [Brand.cyan, Brand.accentBright, Brand.accent], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(6, proxy.size.width * fraction))
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Terpakai \(Int(fraction * 100)) persen")
    }
}

struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: ExpressiveShape(radius: 14, small: 4))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color
    var wash: Color = Brand.sky
    var small: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink2)
            Text(value).font(.system(size: 26, weight: .bold)).tracking(-0.6).monospacedDigit().foregroundStyle(tint)
            Text(caption).font(.caption).foregroundStyle(Brand.ink2).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash, in: ExpressiveShape(radius: 22, small: small))
    }
}

struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let busy = model.busyMessage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.errorMessage {
                dismissable(text: error, symbol: "exclamationmark.triangle.fill", tint: .red) { model.errorMessage = nil }
            }
            if let notice = model.noticeMessage {
                dismissable(text: notice, symbol: "checkmark.circle.fill", tint: .green) { model.noticeMessage = nil }
            }
        }
        .padding(.horizontal)
        .padding(.top, model.busyMessage == nil && model.errorMessage == nil && model.noticeMessage == nil ? 0 : 8)
    }

    func dismissable(text: String, symbol: String, tint: Color, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Date {
    var relativeText: String { Formatters.relative(self) }
}
