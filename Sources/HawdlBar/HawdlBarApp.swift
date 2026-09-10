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

        Toggle(Strings.launchAtLogin, isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Text(model.daemonText)

        if model.needsDaemonHelp {
            Button(Strings.copyStartCommand(MenuModel.startCommand)) {
                model.copyStartCommand()
            }
        }

        Divider()

        Button(Strings.quit) {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
