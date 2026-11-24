import FossifyCommons
import SwiftUI
import UIKit

enum CombinedTab: Hashable, CaseIterable {
    case bookmarks, history, saved

    var title: String {
        switch self {
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .saved: return "Saved pages"
        }
    }
}

/// AddBookmarkPage's input.
struct BookmarkDraft: Hashable {
    var id: UUID?
    var title: String = ""
    var url: String = ""
    var isFolder = false
    var parent: UUID?
}

/// ComboViewActivity: Bookmarks, History and Saved pages tabs.
struct CombinedView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @State private var tab: CombinedTab
    @State private var folder: UUID?
    @State private var confirmClear = false

    init(initial: CombinedTab) {
        _tab = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: tab.title, onBack: {
                if tab == .bookmarks, folder != nil { folder = BookmarkStore.shared.item(folder)?.parent } else { router.pop() }
            }) {
                switch tab {
                case .bookmarks:
                    if let url = model.current?.state.url, !BuiltinPages.isBuiltin(url) {
                        IconButton(icon: "star.badge.plus") {
                            router.push(.bookmarkEditor(BookmarkDraft(title: model.current?.state.title ?? "", url: url.absoluteString, parent: folder)))
                        }
                    }
                    IconButton(icon: "folder.badge.plus") {
                        router.push(.bookmarkEditor(BookmarkDraft(isFolder: true, parent: folder)))
                    }
                case .history:
                    OverflowMenu {
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear history", systemImage: "trash") }
                    }
                case .saved:
                    EmptyView()
                }
            }
            HStack(spacing: 0) {
                ForEach(CombinedTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 0) {
                            Text(t.title).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(t == tab ? palette.primaryColor : palette.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            Rectangle().fill(t == tab ? palette.primaryColor : .clear).frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            switch tab {
            case .bookmarks: BookmarksPage(folder: $folder)
            case .history: HistoryPage()
            case .saved: SavedPagesPage()
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .alert("Clear history", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("OK", role: .destructive) { HistoryStore.shared.clear() }
        } message: {
            Text("History will be cleared.")
        }
    }
}

/// Shared helpers for the list pages.
@MainActor
struct LinkActions {
    let model: BrowserModel
    let router: Router

    func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        router.popToRoot()
        model.load(u)
    }

    func openInNewTab(_ url: String) {
        guard let u = URL(string: url) else { return }
        router.popToRoot()
        model.newTab(u, background: Config.shared.openInBackground)
    }

    func share(_ url: String) {
        if let u = URL(string: url) { model.share = ShareURL(items: [u]) }
    }

    func copy(_ url: String) { model.toast = Launcher.copy(url) }

    func setHomepage(_ url: String) {
        Config.shared.homepage = url
        model.toast = "Homepage set."
    }
}

struct LinkRow: View {
    @Environment(\.palette) private var palette
    let title: String
    let url: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 14) {
            FaviconView(url: url, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? UrlUtils.strip(url) : title).font(.system(size: 16)).foregroundStyle(palette.textColor).lineLimit(1)
                Text(UrlUtils.strip(url)).font(.system(size: 13)).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// BrowserBookmarksPage with the BreadCrumbView and bookmarkscontext.xml.
struct BookmarksPage: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @Binding var folder: UUID?

    var body: some View {
        let store = BookmarkStore.shared
        let actions = LinkActions(model: model, router: router)
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb("Bookmarks", nil)
                    ForEach(store.crumbs(folder)) { f in
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                        crumb(f.title, f.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 40)
            let items = store.children(of: folder)
            if items.isEmpty {
                Text("No bookmarks.").foregroundStyle(palette.secondaryText).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            if item.isFolder {
                                folderRow(item)
                            } else {
                                LinkRow(title: item.title, url: item.url)
                                    .onTapGesture { actions.open(item.url) }
                                    .contextMenu {
                                        Button { actions.open(item.url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                                        Button { actions.openInNewTab(item.url) } label: { Label("Open in new tab", systemImage: "plus.square.on.square") }
                                        Button {
                                            router.push(.bookmarkEditor(BookmarkDraft(id: item.id, title: item.title, url: item.url, parent: item.parent)))
                                        } label: { Label("Edit bookmark", systemImage: "pencil") }
                                        Button { actions.share(item.url) } label: { Label("Share link", systemImage: "square.and.arrow.up") }
                                        Button { actions.copy(item.url) } label: { Label("Copy link URL", systemImage: "link") }
                                        Button { actions.setHomepage(item.url) } label: { Label("Set as homepage", systemImage: "house") }
                                        Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete bookmark", systemImage: "trash") }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private func crumb(_ title: String, _ id: UUID?) -> some View {
        Button { folder = id } label: {
            Text(title).font(.system(size: 14, weight: id == folder ? .semibold : .regular))
                .foregroundStyle(id == folder ? palette.primaryColor : palette.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func folderRow(_ item: Bookmark) -> some View {
        let store = BookmarkStore.shared
        let actions = LinkActions(model: model, router: router)
        return HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(palette.primaryColor).frame(width: 22)
            Text(item.title).font(.system(size: 16)).lineLimit(1)
            Spacer()
            Text("\(store.children(of: item.id).count)").font(.system(size: 13)).foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { folder = item.id }
        .contextMenu {
            Button {
                for b in store.children(of: item.id) where !b.isFolder { actions.openInNewTab(b.url) }
            } label: { Label("Open all in new tabs", systemImage: "plus.square.on.square") }
            Button {
                router.push(.bookmarkEditor(BookmarkDraft(id: item.id, title: item.title, isFolder: true, parent: item.parent)))
            } label: { Label("Edit folder", systemImage: "pencil") }
            Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete folder", systemImage: "trash") }
        }
    }
}

/// BrowserHistoryPage: most visited + DateSorter groups, historycontext.xml.
struct HistoryPage: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @State private var collapsed: Set<String> = ["Most visited"]

    var body: some View {
        let history = HistoryStore.shared
        let groups = history.grouped()
        if groups.isEmpty {
            Text("No history.").foregroundStyle(palette.secondaryText).frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    section("Most visited", history.mostVisited(10))
                    ForEach(groups, id: \.0) { group in
                        section(group.0, group.1)
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ items: [HistoryItem]) -> some View {
        Section {
            if !collapsed.contains(title) {
                ForEach(items) { item in row(item) }
            }
        } header: {
            Button {
                if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
            } label: {
                HStack {
                    Text(title).sectionHeader(palette)
                    Image(systemName: collapsed.contains(title) ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12)).foregroundStyle(palette.primaryColor).padding(.trailing, 16).padding(.top, 16)
                }
                .background(palette.backgroundColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        let actions = LinkActions(model: model, router: router)
        let bookmarks = BookmarkStore.shared
        let starred = bookmarks.isBookmarked(item.url)
        return LinkRow(title: item.title, url: item.url, trailing: AnyView(
            Button {
                if starred { bookmarks.removeURL(item.url) } else { bookmarks.add(title: item.title, url: item.url, parent: nil) }
            } label: {
                Image(systemName: starred ? "star.fill" : "star").foregroundStyle(starred ? palette.primaryColor : palette.secondaryText)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        ))
        .onTapGesture { actions.open(item.url) }
        .contextMenu {
            Button { actions.open(item.url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
            Button { actions.openInNewTab(item.url) } label: { Label("Open in new tab", systemImage: "plus.square.on.square") }
            if starred {
                Button { bookmarks.removeURL(item.url) } label: { Label("Remove from bookmarks", systemImage: "star.slash") }
            } else {
                Button {
                    router.push(.bookmarkEditor(BookmarkDraft(title: item.title, url: item.url)))
                } label: { Label("Save to bookmarks", systemImage: "star") }
            }
            Button { actions.share(item.url) } label: { Label("Share link", systemImage: "square.and.arrow.up") }
            Button { actions.copy(item.url) } label: { Label("Copy link URL", systemImage: "link") }
            Button { actions.setHomepage(item.url) } label: { Label("Set as homepage", systemImage: "house") }
            Button(role: .destructive) { HistoryStore.shared.remove(item.url) } label: { Label("Remove from history", systemImage: "trash") }
        }
    }
}

/// BrowserSnapshotPage: pages saved for offline reading (.webarchive in Download).
struct SavedPagesPage: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette

    var body: some View {
        let store = DownloadStore.shared
        let pages = store.savedPages
        Group {
            if pages.isEmpty {
                Text("No saved pages.").foregroundStyle(palette.secondaryText).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pages, id: \.self) { url in
                            HStack(spacing: 14) {
                                Image(systemName: "doc.richtext").font(.system(size: 20)).foregroundStyle(palette.primaryColor).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 16)).lineLimit(1)
                                    Text(DateTimeFormat.shared.format(store.modified(url)) + " · " + store.size(url).formattedSize)
                                        .font(.system(size: 13)).foregroundStyle(palette.secondaryText)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                router.popToRoot()
                                model.load(url)
                            }
                            .contextMenu {
                                Button {
                                    router.popToRoot()
                                    model.newTab(url)
                                } label: { Label("Open in new tab", systemImage: "plus.square.on.square") }
                                Button { model.share = ShareURL(items: [url]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { store.delete(url) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { store.refresh() }
    }
}

/// AddBookmarkPage: name, address and the folder ("Add to"), or a folder's name.
struct BookmarkEditorView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    let draft: BookmarkDraft
    @State private var title = ""
    @State private var url = ""
    @State private var parent: UUID?
    @State private var newFolder = false
    @State private var folderName = ""

    var body: some View {
        let store = BookmarkStore.shared
        VStack(spacing: 0) {
            TopBar(title: heading, onBack: { router.pop() }) {
                if draft.id != nil {
                    IconButton(icon: "trash") {
                        if let id = draft.id { store.delete(id) }
                        router.pop()
                    }
                }
                IconButton(icon: "checkmark") { save() }.disabled(!valid)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name") { DialogTextField(placeholder: "Name", text: $title) }
                    if !draft.isFolder {
                        field("Address") { DialogTextField(placeholder: "Address", text: $url).keyboardType(.URL) }
                    }
                    field(draft.isFolder ? "Parent folder" : "Add to") {
                        HStack {
                            Menu {
                                Button("Bookmarks") { parent = nil }
                                ForEach(store.folders(excluding: draft.isFolder ? draft.id : nil)) { f in
                                    Button(store.path(of: f.id)) { parent = f.id }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(store.path(of: parent)).lineLimit(1)
                                    Image(systemName: "chevron.down").font(.system(size: 12))
                                }
                                .foregroundStyle(palette.textColor)
                            }
                            Spacer()
                            Button("New folder") { newFolder = true }.foregroundStyle(palette.primaryColor)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .onAppear {
            title = draft.title
            url = draft.url
            parent = draft.parent
        }
        .sheet(isPresented: $newFolder) {
            DialogFrame(title: "New folder") {
                DialogTextField(placeholder: "Folder name", text: $folderName)
                DialogButtons(okEnabled: !folderName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    parent = store.addFolder(folderName.trimmingCharacters(in: .whitespaces), parent: parent)
                    folderName = ""
                    newFolder = false
                }
            }
        }
    }

    private var heading: String {
        if draft.isFolder { return draft.id == nil ? "New folder" : "Edit folder" }
        return draft.id == nil ? "Bookmark this page" : "Edit bookmark"
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && (draft.isFolder || !url.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.primaryColor)
            content()
        }
    }

    private func save() {
        let store = BookmarkStore.shared
        let name = title.trimmingCharacters(in: .whitespaces)
        if draft.isFolder {
            if let id = draft.id, var f = store.item(id) {
                f.title = name
                f.parent = parent
                store.upsert(f)
            } else {
                store.addFolder(name, parent: parent)
            }
        } else {
            let address = (UrlUtils.smartUrl(url) ?? URL(string: url))?.absoluteString ?? url
            if let id = draft.id, var b = store.item(id) {
                b.title = name
                b.url = address
                b.parent = parent
                store.upsert(b)
            } else {
                store.add(title: name, url: address, parent: parent)
                model.toast = "Saved to bookmarks."
            }
        }
        router.pop()
    }
}

/// The downloads list (DownloadManager's UI): running downloads and Documents/Download.
struct DownloadsView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette

    var body: some View {
        let store = DownloadStore.shared
        VStack(spacing: 0) {
            TopBar(title: "Downloads")
            if store.active.isEmpty && store.files.isEmpty {
                Text("No downloads.").foregroundStyle(palette.secondaryText).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.active) { item in
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(palette.primaryColor)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.filename).font(.system(size: 16)).lineLimit(1)
                                    ProgressView(value: item.progress).tint(palette.primaryColor)
                                }
                                IconButton(icon: "xmark") { item.cancelHandler?() }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        ForEach(store.files, id: \.self) { url in
                            HStack(spacing: 14) {
                                Image(systemName: icon(url)).font(.system(size: 20)).foregroundStyle(palette.primaryColor).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).font(.system(size: 16)).lineLimit(1)
                                    Text(DateTimeFormat.shared.format(store.modified(url)) + " · " + store.size(url).formattedSize)
                                        .font(.system(size: 13)).foregroundStyle(palette.secondaryText)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { open(url) }
                            .contextMenu {
                                Button { open(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                                Button { Launcher.openWith(url) } label: { Label("Open with", systemImage: "square.grid.2x2") }
                                Button { model.share = ShareURL(items: [url]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { store.delete(url) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .onAppear { store.refresh() }
    }

    private func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "webarchive", "html", "htm": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo"
        case "pdf": return "doc.text"
        case "mp3", "m4a", "ogg", "wav": return "music.note"
        case "mp4", "mov", "webm": return "film"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }

    /// Web content opens in a tab; anything else goes to "Open with".
    private func open(_ url: URL) {
        let web = ["webarchive", "html", "htm", "xhtml", "txt", "pdf", "jpg", "jpeg", "png", "gif", "webp", "svg"]
        if web.contains(url.pathExtension.lowercased()) {
            router.popToRoot()
            model.newTab(url)
        } else if !Launcher.openWith(url) {
            model.toast = "No app found to open this file"
        }
    }
}
