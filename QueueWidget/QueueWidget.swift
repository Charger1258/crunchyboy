import SwiftUI
import WidgetKit
import ImageIO

struct QueueEntry: TimelineEntry {
    let date: Date
    let snapshot: QueueSnapshot?
    var images: [String: UIImage] = [:]
}

struct QueueProvider: TimelineProvider {
    func placeholder(in context: Context) -> QueueEntry {
        QueueEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (QueueEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : QueueEntry(date: .now, snapshot: QueueSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QueueEntry>) -> Void) {
        Task {
            let saved = QueueSnapshotStore.read()
            let snapshot: QueueSnapshot?
            if let saved { snapshot = await QueueRefresh.refresh(saved) }
            else { snapshot = nil }
            var images: [String: UIImage] = [:]
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for item in Array(snapshot?.items.prefix(4) ?? []) {
                    group.addTask { (item.id, await Self.image(item.artwork)) }
                }
                for await (id, image) in group { images[id] = image }
            }
            let entry = QueueEntry(date: .now, snapshot: snapshot, images: images)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
        }
    }

    private static func image(_ url: URL?) async -> UIImage? {
        guard let url, url.scheme == "https" else { return nil }
        do {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= 4_000_000 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4_000_000 else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        } catch { return nil }
    }
}

@main struct StreamAnimeQueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QueueSnapshot.kind, provider: QueueProvider()) { entry in
            QueueWidgetContent(snapshot: entry.snapshot, images: entry.images)
        }
        .configurationDisplayName("Queue")
        .description("Continue anime from your active Stream Anime profile.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
