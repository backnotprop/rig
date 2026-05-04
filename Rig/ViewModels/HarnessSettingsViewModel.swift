import Foundation
import SwiftUI

@MainActor
final class HarnessSettingsViewModel: ObservableObject {
    @Published var harnesses: [LauncherHarness]

    init(harnesses: [LauncherHarness] = LauncherHarness.defaults) {
        self.harnesses = harnesses
    }
}
