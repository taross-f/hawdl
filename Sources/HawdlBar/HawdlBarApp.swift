import HawdlCore
import SwiftUI

@main
struct HawdlBarApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.symbolName)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        Text(model.stateText)
            .onAppear { model.refreshLaunchAtLogin() }

        Divider()

        Button(model.toggleTitle) {
            model.toggle()
        }
        .disabled(!model.canToggle)

        Toggle("ログイン時に起動", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Text(model.daemonText)

        if model.needsDaemonHelp {
            Button("起動コマンドをコピー (\(MenuModel.startCommand))") {
                model.copyStartCommand()
            }
        }

        Divider()

        Button("終了") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
