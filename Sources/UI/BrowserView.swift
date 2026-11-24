import FossifyCommons
import SwiftUI
import UIKit

/// PhoneUi: title bar (NavigationBarPhone), progress, the current tab's web view,
/// url suggestions, find-in-page and the tab switcher (NavScreen).
struct BrowserView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var editing = false
    @State private var input = ""
    @State private var finding = false
    @State private var pageInfo = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if finding, let tab = model.current {
                    FindBar(tab: tab) { finding = false }
                } else {
                    TitleBar(editing: $editing, input: $input, finding: $finding, pageInfo: $pageInfo)
                }
                ZStack(alignment: .top) {
                    if let tab = model.current {
                        if let page = tab.page {
                            PageView(page: page)
                                .ignoresSafeArea(edges: .bottom)
                        } else {
                            // The page is made outside the view update (it starts loading at once).
                            palette.backgroundColor.task(id: tab.id) { _ = model.page(for: tab) }
                        }
                        ProgressBar(state: tab.state)
                    }
                    if editing {
                        SuggestionsView(input: $input) { text in
                            submit(text)
                        }
                    }
                }
            }
            .background(palette.backgroundColor.ignoresSafeArea())
            if model.showTabs {
                NavScreen()
                    .transition(.asymmetric(insertion: .scale(scale: 1.1).combined(with: .opacity), removal: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showTabs)
        .sheet(isPresented: $pageInfo) { PageInfoDialog() }
    }

    private func submit(_ text: String) {
        editing = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        model.load(text)
    }
}

/// PageProgressView: a thin primary-colored line under the title bar.
struct ProgressBar: View {
    @Environment(\.palette) private var palette
    let state: PageState

    var body: some View {
        GeometryReader { geo in
            if state.isLoading {
                Rectangle().fill(palette.primaryColor)
                    .frame(width: geo.size.width * max(0.05, state.progress), height: 3)
                    .animation(.linear(duration: 0.2), value: state.progress)
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}

/// Hosts a page's view; swapping tabs swaps the subview without recreating it.
struct PageView: UIViewRepresentable {
    let page: BrowserPage

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        embed(container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if page.view.superview !== container { embed(container) }
    }

    private func embed(_ container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = page.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

/// NavigationBarPhone: favicon/lock, url input, stop/reload, tab switcher, menu.
struct TitleBar: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @Binding var editing: Bool
    @Binding var input: String
    @Binding var finding: Bool
    @Binding var pageInfo: Bool

    var body: some View {
        let tab = model.current
        let state = tab?.state
        let incognito = tab?.incognito ?? false
        let tint = incognito ? Color.white : palette.textColor
        HStack(spacing: 0) {
            if !editing { CloseAppButton() }
            HStack(spacing: 6) {
                if editing {
                    Image(systemName: "magnifyingglass").foregroundStyle(tint.opacity(0.6)).frame(width: 22)
                } else if incognito {
                    Image(systemName: "eyeglasses").foregroundStyle(tint).frame(width: 22)
                } else if state?.isSecure == true {
                    Image(systemName: "lock.fill").font(.system(size: 14)).foregroundStyle(palette.primaryColor).frame(width: 22)
                        .onTapGesture { pageInfo = true }
                } else if let url = state?.url, !BuiltinPages.isBuiltin(url) {
                    FaviconView(url: url.absoluteString, size: 18).frame(width: 22).onTapGesture { pageInfo = true }
                } else {
                    Image(systemName: "globe").foregroundStyle(tint.opacity(0.6)).frame(width: 22)
                }
                UrlField(text: $input, editing: $editing, placeholder: "Search or type URL", textColor: UIColor(tint)) { submitted in
                    editing = false
                    model.load(submitted)
                }
                .frame(height: 36)
                if editing {
                    if !input.isEmpty {
                        Button { input = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(tint.opacity(0.5))
                        }
                    }
                } else if let state {
                    Button {
                        if state.isLoading { model.current?.page?.stop() } else { model.current?.page?.reload() }
                    } label: {
                        Image(systemName: state.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 15))
                            .foregroundStyle(tint).frame(width: 30, height: 36)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 18).fill(tint.opacity(0.08)))
            .padding(.leading, editing ? 8 : 0)
            .padding(.vertical, 6)
            if editing {
                Button("Cancel") {
                    editing = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .foregroundStyle(incognito ? .white : palette.primaryColor)
                .padding(.horizontal, 12)
            } else {
                Button { model.showTabs = true } label: {
                    Text("\(model.tabs.count)")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint, lineWidth: 2))
                        .frame(width: 44, height: 48)
                }
                .foregroundStyle(tint)
                BrowserMenu(finding: $finding, pageInfo: $pageInfo).foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 56)
        .background((incognito ? Color(white: 0.2) : palette.backgroundColor).ignoresSafeArea(edges: .top))
        .onChange(of: editing) { _, on in if on { input = editText } }
        .onChange(of: model.current?.state.url) { _, _ in if !editing { input = displayText } }
        .onChange(of: model.currentID, initial: true) { _, _ in if !editing { input = displayText } }
        .onChange(of: editing) { _, on in if !on { input = displayText } }
    }

    /// What the bar shows: the search terms on a result page, else the url.
    private var displayText: String {
        guard let url = model.current?.state.url, !BuiltinPages.isBuiltin(url), url.absoluteString != Homepage.blank else { return "" }
        return config.engine.query(from: url) ?? url.absoluteString
    }

    private var editText: String {
        guard let url = model.current?.state.url, !BuiltinPages.isBuiltin(url), url.absoluteString != Homepage.blank else { return "" }
        return config.engine.query(from: url) ?? url.absoluteString
    }
}

/// The options menu (res/menu/browser.xml, phone).
struct BrowserMenu: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Binding var finding: Bool
    @Binding var pageInfo: Bool

    var body: some View {
        let tab = model.current
        let state = tab?.state
        let url = state?.url
        let isWeb = url != nil && !BuiltinPages.isBuiltin(url)
        OverflowMenu {
            ControlGroup {
                Button { tab?.page?.goBack() } label: { Label("Back", systemImage: "arrow.left") }
                    .disabled(state?.canGoBack != true)
                Button { tab?.page?.goForward() } label: { Label("Forward", systemImage: "arrow.right") }
                    .disabled(state?.canGoForward != true)
                if state?.isLoading == true {
                    Button { tab?.page?.stop() } label: { Label("Stop", systemImage: "xmark") }
                } else {
                    Button { tab?.page?.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
            Button { model.goHome() } label: { Label("Homepage", systemImage: "house") }
            Section {
                Button { model.newTab(nil) } label: { Label("New tab", systemImage: "plus.square.on.square") }
                Button { model.newTab(nil, incognito: true) } label: { Label("New incognito tab", systemImage: "eyeglasses") }
            }
            Section {
                Button { router.push(.combined(.bookmarks)) } label: { Label("Bookmarks", systemImage: "star") }
                if isWeb, let url {
                    Button {
                        router.push(.bookmarkEditor(BookmarkDraft(title: state?.title ?? "", url: url.absoluteString)))
                    } label: { Label("Save to bookmarks", systemImage: "star.badge.plus") }
                }
                Button { router.push(.combined(.history)) } label: { Label("History", systemImage: "clock") }
                Button { router.push(.combined(.saved)) } label: { Label("Saved pages", systemImage: "doc.richtext") }
                Button { router.push(.downloads) } label: { Label("Downloads", systemImage: "arrow.down.circle") }
            }
            if isWeb {
                Section {
                    Button { model.sharePage() } label: { Label("Share page", systemImage: "square.and.arrow.up") }
                    Button { finding = true } label: { Label("Find on page", systemImage: "doc.text.magnifyingglass") }
                    Toggle(isOn: Binding(get: { state?.desktopMode ?? false }, set: { tab?.page?.setDesktopMode($0) })) {
                        Label("Request desktop site", systemImage: "desktopcomputer")
                    }
                    Button { model.savePage() } label: { Label("Save for offline reading", systemImage: "square.and.arrow.down") }
                    Button { pageInfo = true } label: { Label("Page info", systemImage: "info.circle") }
                }
            }
            Button { router.push(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// FindActionModeCallback: query, "n of m", previous/next, done.
struct FindBar: View {
    @Environment(\.palette) private var palette
    let tab: BrowserTab
    let onClose: () -> Void
    @State private var text = ""
    @State private var result = (0, 0)
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            IconButton(icon: "checkmark") { close() }
            TextField("Find on page", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { step(false) }
                .padding(.horizontal, 8)
            if !text.isEmpty {
                Text(result.1 == 0 ? "No matches" : "\(result.0) of \(result.1)")
                    .font(.system(size: 13)).foregroundStyle(palette.secondaryText)
            }
            IconButton(icon: "chevron.up") { step(true) }.disabled(result.1 == 0)
            IconButton(icon: "chevron.down") { step(false) }.disabled(result.1 == 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 56)
        .background(palette.backgroundColor.ignoresSafeArea(edges: .top))
        .onAppear { focused = true }
        .onChange(of: text) { _, value in
            Task { result = await tab.page?.find(value, backwards: false, restart: true) ?? (0, 0) }
        }
    }

    private func step(_ backwards: Bool) {
        Task { result = await tab.page?.find(text, backwards: backwards, restart: false) ?? (0, 0) }
    }

    private func close() {
        tab.page?.clearFind()
        onClose()
    }
}

/// UrlInputView: a UITextField that selects everything when editing starts.
struct UrlField: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    var placeholder: String
    var textColor: UIColor
    var onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.textContentType = .URL
        field.font = .systemFont(ofSize: 16)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.textColor = textColor
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: textColor.withAlphaComponent(0.5)])
        if !editing && field.isFirstResponder { field.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UrlField

        init(_ parent: UrlField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.editing = true
            DispatchQueue.main.async {
                field.text = self.parent.text
                field.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.editing { parent.editing = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            let value = field.text ?? ""
            field.resignFirstResponder()
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { parent.onSubmit(value) }
            return false
        }
    }
}

/// SuggestionsAdapter: the typed text, bookmarks, history and the search engine's suggestions.
struct SuggestionsView: View {
    @Environment(\.palette) private var palette
    @Environment(Config.self) private var config
    @Binding var input: String
    let onPick: (String) -> Void
    @State private var remote: [String] = []

    var body: some View {
        let query = input.trimmingCharacters(in: .whitespaces)
        let bookmarks = query.isEmpty ? [] : BookmarkStore.shared.matching(query)
        let bookmarked = Set(bookmarks.map(\.url))
        let history = query.isEmpty ? HistoryStore.shared.mostVisited(6) : HistoryStore.shared.matching(query).filter { !bookmarked.contains($0.url) }
        ScrollView {
            LazyVStack(spacing: 0) {
                if !query.isEmpty {
                    let isURL = UrlUtils.smartUrl(query) != nil
                    row(icon: isURL ? "globe" : "magnifyingglass", title: query,
                        subtitle: isURL ? nil : "Search \(config.engine.label)", value: query)
                }
                ForEach(bookmarks) { b in
                    row(icon: "star.fill", title: b.title, subtitle: UrlUtils.strip(b.url), value: b.url)
                }
                ForEach(history) { h in
                    row(icon: "clock", title: h.title.isEmpty ? UrlUtils.strip(h.url) : h.title, subtitle: UrlUtils.strip(h.url), value: h.url)
                }
                ForEach(remote.filter { $0 != query }, id: \.self) { s in
                    row(icon: "magnifyingglass", title: s, subtitle: nil, value: s)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(palette.backgroundColor)
        .task(id: query) {
            guard config.searchSuggestions, !query.isEmpty, UrlUtils.smartUrl(query) == nil else {
                remote = []
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            remote = await config.engine.suggestions(for: query)
        }
    }

    private func row(icon: String, title: String, subtitle: String?, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(palette.secondaryText).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(palette.textColor).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.primaryColor).lineLimit(1)
                }
            }
            Spacer()
            // The "insert" arrow: put the suggestion into the field to refine it.
            Button { input = value } label: {
                Image(systemName: "arrow.up.left").font(.system(size: 15)).foregroundStyle(palette.secondaryText)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onPick(value) }
    }
}

/// PageDialogsHandler.showPageInfo.
struct PageInfoDialog: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var showCertificate = false

    var body: some View {
        let tab = model.current
        DialogFrame(title: "Page info") {
            Text(tab?.displayTitle ?? "").font(.system(size: 17, weight: .medium)).padding(.bottom, 6)
            Text(tab?.state.url?.absoluteString ?? "").font(.system(size: 14)).foregroundStyle(palette.secondaryText)
                .textSelection(.enabled)
            if tab?.state.url?.scheme == "https" {
                Text(tab?.state.isSecure == true ? "Connection is secure." : "Parts of this page are not secure.")
                    .font(.system(size: 14)).padding(.top, 12)
                if showCertificate {
                    Text(tab?.page?.certificateSummary ?? "No certificate")
                        .font(.system(size: 14)).foregroundStyle(palette.secondaryText).padding(.top, 8)
                }
            }
            HStack(spacing: 24) {
                Spacer()
                if tab?.state.url?.scheme == "https" && !showCertificate {
                    Button("View certificate") { showCertificate = true }
                }
                Button("OK") { dismiss() }
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(palette.primaryColor)
            .padding(.top, 16)
        }
    }
}

/// JsDialogHelper / HttpAuthenticationDialog / PermissionsPrompt / the SSL warning.
struct PromptDialog: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let prompt: PagePrompt
    @State private var answered = false
    @State private var text = ""
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        content
            .onAppear {
                if case .textInput(_, let defaultText, _) = prompt.kind { text = defaultText }
            }
            .onDisappear { if !answered { cancel() } }
    }

    @ViewBuilder
    private var content: some View {
        switch prompt.kind {
        case .alert(let message, let done):
            DialogFrame(title: "The page at \(prompt.origin) says:") {
                Text(message).padding(.bottom, 8)
                buttons(cancel: nil) { done() }
            }
        case .confirm(let message, let done):
            DialogFrame(title: "The page at \(prompt.origin) says:") {
                Text(message).padding(.bottom, 8)
                buttons(cancel: { done(false) }) { done(true) }
            }
        case .textInput(let message, _, let done):
            DialogFrame(title: "The page at \(prompt.origin) says:") {
                Text(message)
                DialogTextField(placeholder: "", text: $text)
                buttons(cancel: { done(nil) }) { done(text) }
            }
        case .httpAuth(let host, let realm, let done):
            DialogFrame(title: "Sign in to \(host) \"\(realm)\"") {
                DialogTextField(placeholder: "Username", text: $user)
                DialogTextField(placeholder: "Password", text: $password, secure: true)
                buttons(ok: "Sign in", cancel: { done(nil) }) { done((user, password)) }
            }
        case .permission(let kinds, let done):
            let what = kinds == [.location] ? "wants to know your location"
                : "wants to use your " + kinds.map { $0.title.lowercased() }.joined(separator: " and ")
            DialogFrame(title: nil) {
                Text("\(prompt.origin) \(what)").font(.system(size: 17)).padding(.bottom, 8)
                CheckRow(title: "Remember preference", on: $remember)
                buttons(ok: kinds == [.location] ? "Share location" : "Allow", cancelTitle: "Decline", cancel: { done(false, remember) }) {
                    done(true, remember)
                }
            }
        case .certificate(let message, let done):
            DialogFrame(title: "Security warning") {
                Text(message).padding(.bottom, 4)
                Text("This certificate isn't from a trusted authority.").font(.system(size: 14)).foregroundStyle(palette.secondaryText)
                buttons(ok: "Continue", cancelTitle: "Go back", cancel: { done(false) }) { done(true) }
            }
        }
    }

    private func buttons(ok: String = "OK", cancelTitle: String = "Cancel", cancel: (() -> Void)?, onOK: @escaping () -> Void) -> some View {
        HStack(spacing: 24) {
            Spacer()
            if let cancel {
                Button(cancelTitle) {
                    answered = true
                    cancel()
                    dismiss()
                }
            }
            Button(ok) {
                answered = true
                onOK()
                dismiss()
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(palette.primaryColor)
        .padding(.top, 16)
    }

    /// Dismissed without an answer: the negative choice.
    private func cancel() {
        switch prompt.kind {
        case .alert(_, let done): done()
        case .confirm(_, let done): done(false)
        case .textInput(_, _, let done): done(nil)
        case .httpAuth(_, _, let done): done(nil)
        case .permission(_, let done): done(false, false)
        case .certificate(_, let done): done(false)
        }
    }
}
