import UIKit

/// Puts a "Done" bar above the keyboard for EVERY text field and text
/// view in the app - search bars, add-customer forms, notes, sheets
/// included - so there is always a visible way to put the keyboard
/// away. Before this the app had none: the customer search opened the
/// keyboard and nothing on screen closed it again.
///
/// Done app-wide from one place instead of a SwiftUI `.toolbar(.keyboard)`
/// on each screen, because those don't carry into sheets (every sheet
/// is its own hosting controller) and stack into duplicate Done buttons
/// when a parent and child both declare one.
///
/// Call `KeyboardDoneBar.install()` once at launch.
enum KeyboardDoneBar {

    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UITextField.textDidBeginEditingNotification,
                               object: nil, queue: .main) { note in
                guard let field = note.object as? UITextField,
                      field.inputAccessoryView == nil else { return }
                field.inputAccessoryView = makeBar()
                field.reloadInputViews()
            },
            center.addObserver(forName: UITextView.textDidBeginEditingNotification,
                               object: nil, queue: .main) { note in
                guard let view = note.object as? UITextView,
                      view.isEditable,
                      view.inputAccessoryView == nil else { return }
                view.inputAccessoryView = makeBar()
                view.reloadInputViews()
            }
        ]
    }

    private static func makeBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            })
        ]
        bar.sizeToFit()
        return bar
    }
}
