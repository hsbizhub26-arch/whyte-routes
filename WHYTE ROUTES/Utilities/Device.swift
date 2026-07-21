import UIKit

enum Device {
    static var isSmallScreen: Bool {
        UIScreen.main.bounds.height < 700
    }

    static var isiPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var notch: Bool {
        let bottom = UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
        return bottom > 0
    }
}
