import SwiftUI

enum AnimeTheme {
    static let background = Color(red: 11/255, green: 11/255, blue: 13/255)
    static let surface = Color(red: 32/255, green: 32/255, blue: 36/255)
    static let accent = Color(red: 1, green: 100/255, blue: 10/255)
}

struct ProfileAvatar: View {
    let symbol: String
    var size: CGFloat = 80
    var selected = false
    var image: Data? = nil
    private var color: Color {
        let colors: [Color] = [AnimeTheme.accent, .purple, .pink, .indigo, .red, .teal]
        return colors[ViewerProfile.symbols.firstIndex(of: symbol) ?? 0]
    }
    var body: some View {
        Group {
            if let image, let picture = UIImage(data: image) {
                Image(uiImage: picture).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.43, weight: .semibold)).foregroundStyle(.white)
            }
        }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
            .background(LinearGradient(colors: [color.opacity(0.8), color.opacity(0.18), AnimeTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(selected ? AnimeTheme.accent : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
    }
}
