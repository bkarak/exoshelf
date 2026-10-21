import ExoShelfCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSetup:
                SetupView()
            case .ready:
                LibraryView()
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }
}
