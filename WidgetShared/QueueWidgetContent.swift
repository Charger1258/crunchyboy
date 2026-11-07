import SwiftUI
import WidgetKit

struct QueueWidgetContent: View {
    let snapshot: QueueSnapshot?
    var images: [String: UIImage] = [:]
    @Environment(\.widgetFamily) private var family
    private let accent = Color(red: 1, green: 0.48, blue: 0)
    private var limit: Int { family == .systemSmall ? 1 : family == .systemLarge ? 4 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Queue", systemImage: "play.stack.fill")
                    .font(.headline).foregroundStyle(accent)
                Spacer(minLength: 4)
                if family != .systemSmall, let snapshot {
                    Text(snapshot.profileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let snapshot, !snapshot.items.isEmpty {
                ForEach(Array(snapshot.items.prefix(limit))) { item in
                    Link(destination: snapshot.link(for: item)) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08))
                                if let image = images[item.id] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "play.rectangle.fill").foregroundStyle(accent)
                                }
                            }
                            .frame(width: family == .systemSmall ? 38 : 64, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Text(item.episode).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if family != .systemSmall {
                                Image(systemName: "play.fill").font(.caption).foregroundStyle(accent)
                            }
                        }.foregroundStyle(.white)
                    }.accessibilityLabel("Watch \(item.title), \(item.episode)")
                }
                Spacer(minLength: 0)
                if family == .systemSmall {
                    Text(snapshot.profileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                Image(systemName: snapshot == nil ? "play.circle" : "checkmark.circle")
                    .font(.title2).foregroundStyle(accent)
                Text(snapshot == nil ? "Open Stream Anime" : "All caught up")
                    .font(.subheadline.bold())
                Text(snapshot == nil ? "Open the app to set up your Queue." : "Checking periodically for new episodes.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(snapshot?.link() ?? URL(string: "streamanime://queue"))
        .containerBackground(Color(red: 0.045, green: 0.045, blue: 0.055), for: .widget)
    }
}
