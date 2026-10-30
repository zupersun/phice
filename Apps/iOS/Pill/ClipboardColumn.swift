import PhiceCore
import SwiftUI

/// The clipboard column's contents: recent items from the Mac, as many as fit. Touches are handled
/// by `PillLayer`, which knows each row's rect from `PillGeometry`.
struct ClipboardColumn: View {
    let geometry: PillGeometry
    let items: [ClipItem]
    /// The item being dragged out, left behind as a ghost.
    let carried: String?
    /// VoiceOver's way to paste a row, since it cannot drag one out.
    let paste: (ClipItem) -> Void

    var body: some View {
        let column = geometry.column
        ZStack {
            Text("Clipboard")
                .font(.system(size: 16, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Palette.mute)
                .frame(width: geometry.row(0).width, alignment: .leading)
                .position(x: geometry.row(0).midX,
                          y: column.minY + PillGeometry.columnPadding
                              + PillGeometry.headerHeight / 2 - 4)
            if items.isEmpty {
                Text("Copy something on your Mac")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.mute)
                    .position(x: geometry.row(0).midX, y: geometry.row(0).midY)
            }
            // shortcut: shows only the rows that fit; scroll the column once history needs it.
            let shown = Array(items.prefix(geometry.rowCount).enumerated())
            ForEach(shown, id: \.element.id) { index, item in
                let rect = geometry.row(index)
                ClipRow(item: item, ghost: item.id == carried)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityAction(named: "Paste") { paste(item) }
                if index < shown.count - 1 {
                    Rectangle().fill(Palette.line)
                        .frame(width: rect.width, height: 1)
                        .position(x: rect.midX, y: rect.maxY + PillGeometry.rowGap / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One clipboard entry: an icon well and a one-line preview, on the column's black. Dragged out it
/// becomes a small pill of its own: black, with the pill's white border.
struct ClipRow: View {
    let item: ClipItem
    var ghost = false
    var lifted = false
    var border = 1.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 11) {
            icon
            Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 19))
                .lineLimit(1)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
        .background(lifted ? Color.black : Color.clear, in: shape)
        .overlay {
            if ghost {
                shape.strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if lifted {
                shape.strokeBorder(Color.white.opacity(border), lineWidth: PillGeometry.border)
            }
        }
        .opacity(ghost ? 0.3 : 1)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        let well = RoundedRectangle(cornerRadius: 5)
        return ZStack {
            well.fill(Palette.well)
            if let data = item.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.mute)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(well)
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
