import Records
import SwiftUI

/// An album's editable fields, bound to whatever edits it.
struct AlbumFieldsSection: View {
    @Binding var album: Album
    let title: String

    var body: some View {
        Section(title) {
            TextField("Title", text: $album.title)
            Stepper(value: $album.year, in: 1900...2100) {
                LabeledContent("Year", value: String(album.year))
            }
            Picker("Rating", selection: $album.rating) {
                Text("None").tag(Rating?.none)
                ForEach(Rating.allCases, id: \.self) { rating in
                    Text(String(repeating: "★", count: rating.rawValue)).tag(Rating?.some(rating))
                }
            }
            TextField("Notes (encrypted)", text: Binding(
                get: { album.notes ?? "" },
                set: { album.notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
        }
    }
}

/// One editor with its own `@Recordable`, so it is one pending edit of its own.
struct AlbumEditor: View {
    @Recordable var album: Album
    let title: String

    init(album: Album, title: String) {
        _album = Recordable(album)
        self.title = title
    }

    var body: some View {
        AlbumFieldsSection(album: $album, title: title)
    }
}

/// Two editors on the same album, with the pending changes they make.
struct SplitAlbumEditor: View {
    let album: Album

    var body: some View {
        Form {
            AlbumEditor(album: album, title: "Top editor")
            AlbumEditor(album: album, title: "Bottom editor")
            PendingChangesSection()
        }
    }
}

/// The context's pending changes, as they begin and end.
struct PendingChangesSection: View {
    @Environment(\.recordContext) private var context

    var body: some View {
        Section("Pending changes") {
            if context.changes.isEmpty {
                Label("None", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(context.changes.enumerated()), id: \.offset) { _, change in
                ChangeLabel(change: change)
            }
        }
    }
}

struct ChangeLabel: View {
    let change: RecordDifference.Change

    var body: some View {
        switch change {
        case .insert(let id):
            Label("Insert \(id.uuidString.prefix(8))", systemImage: "plus.circle.fill").foregroundStyle(.green)
        case .update(let id):
            Label("Update \(id.uuidString.prefix(8))", systemImage: "pencil.circle.fill").foregroundStyle(.blue)
        case .delete(let id):
            Label("Delete \(id.uuidString.prefix(8))", systemImage: "minus.circle.fill").foregroundStyle(.red)
        }
    }
}

/// An album read through `@Recordable`, so it follows every save without being told.
struct LiveAlbumCard: View {
    @Recordable var album: Album
    @Environment(\.recordContext) private var context

    init(album: Album) {
        _album = Recordable(album)
    }

    var body: some View {
        VStack(spacing: 16) {
            CoverImage(url: album.$cover, size: 160)
            Text(album.title)
                .font(.largeTitle.bold())
                .contentTransition(.numericText())
            Stars(count: album.rating?.rawValue ?? 0)
                .font(.title2)
            if let saved = context.events.lastSaved {
                Label("Saved at \(saved.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
        .animation(.default, value: album.title)
        .padding()
    }
}

struct Stars: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= count ? "star.fill" : "star")
                    .foregroundStyle(star <= count ? Color.yellow : Color.secondary)
            }
        }
    }
}

/// An image read from an asset's file.
struct CoverImage: View {
    let url: URL?
    var size: CGFloat = 52
    var symbol = "music.note"

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14))
    }
}

/// Save and Revert, enabled while changes are pending. A failed save is shown and printed.
struct SaveControls: View {
    @Environment(\.recordContext) private var context
    @State private var failure: String?

    var body: some View {
        HStack {
            Button("Revert", systemImage: "arrow.uturn.backward") {
                context.rollback()
            }
            .disabled(!context.hasChanges)
            Button("Save", systemImage: "square.and.arrow.down") {
                do {
                    try context.save()
                } catch {
                    failure = String(describing: error)
                    print("LAB FAIL save: \(error)")
                }
            }
            .disabled(!context.hasChanges)
        }
        .alert("Save failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }
}
