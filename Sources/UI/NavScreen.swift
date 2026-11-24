import FossifyCommons
import SwiftUI
import UIKit

/// NavScreen: the phone tab switcher. Cards (NavTabView) with the title bar,
/// close button and the page thumbnail; swipe a card sideways to close it.
struct NavScreen: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButton(icon: "arrow.left") { model.showTabs = false }
                Text("Tabs").font(.system(size: 21, weight: .medium))
                Spacer()
                IconButton(icon: "star") {
                    model.showTabs = false
                    router.push(.combined(.bookmarks))
                }
                IconButton(icon: "plus") { model.newTab(nil) }
                OverflowMenu {
                    Button { model.newTab(nil, incognito: true) } label: { Label("New incognito tab", systemImage: "eyeglasses") }
                    Button { model.closeOthers() } label: { Label("Close other tabs", systemImage: "xmark.square") }
                        .disabled(model.tabs.count < 2)
                    if model.tabs.contains(where: \.incognito) {
                        Button { model.closeAllIncognito() } label: { Label("Close incognito tabs", systemImage: "eyeglasses") }
                    }
                    Button {
                        model.showTabs = false
                        router.push(.settings)
                    } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 56)
            ScrollViewReader { proxy in
                let horizontal = vertical == .compact
                ScrollView(horizontal ? .horizontal : .vertical) {
                    let cards = ForEach(model.tabs) { tab in
                        NavTabCard(tab: tab, current: tab.id == model.current?.id, horizontal: horizontal)
                            .id(tab.id)
                    }
                    if horizontal {
                        LazyHStack(spacing: 16) { cards }.padding(16)
                    } else {
                        LazyVStack(spacing: 16) { cards }.padding(16)
                    }
                }
                .onAppear { proxy.scrollTo(model.current?.id, anchor: .center) }
            }
        }
        .background(palette.backgroundColor.mix(with: palette.textColor, by: 0.06).ignoresSafeArea())
    }
}

struct NavTabCard: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette
    let tab: BrowserTab
    let current: Bool
    let horizontal: Bool
    @State private var offset: CGFloat = 0

    var body: some View {
        let barColor = tab.incognito ? Color(white: 0.2) : palette.surface
        let barText = tab.incognito ? Color.white : palette.textColor
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if tab.incognito {
                    Image(systemName: "eyeglasses").foregroundStyle(barText)
                } else if let url = tab.state.url, !BuiltinPages.isBuiltin(url) {
                    FaviconView(url: url.absoluteString, size: 16)
                } else {
                    Image(systemName: "globe").foregroundStyle(barText.opacity(0.6))
                }
                Text(tab.displayTitle).font(.system(size: 14)).foregroundStyle(barText).lineLimit(1)
                Spacer()
                Button { withAnimation { model.close(tab) } } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(barText)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .frame(height: 40)
            .background(barColor)
            ZStack {
                Color.white
                if let image = tab.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    Image(systemName: tab.incognito ? "eyeglasses" : "globe").font(.system(size: 40)).foregroundStyle(.gray.opacity(0.4))
                }
            }
            .clipped()
        }
        .frame(width: horizontal ? 260 : nil, height: horizontal ? 220 : 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? palette.primaryColor : palette.divider, lineWidth: current ? 3 : 1))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .offset(x: horizontal ? 0 : offset, y: horizontal ? offset : 0)
        .opacity(1 - Double(min(abs(offset) / 300, 0.7)))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let d = horizontal ? value.translation.height : value.translation.width
                    let other = horizontal ? value.translation.width : value.translation.height
                    if abs(d) > abs(other) { offset = d }
                }
                .onEnded { _ in
                    if abs(offset) > 120 {
                        withAnimation(.easeOut(duration: 0.15)) { offset = offset > 0 ? 600 : -600 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { model.close(tab) } }
                    } else {
                        withAnimation { offset = 0 }
                    }
                }
        )
    }
}
