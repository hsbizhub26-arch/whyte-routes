import Foundation
import FirebaseAuth

// Shared ordering/labelling for every "assign a driver" picker.
//
// The bug this fixes: an owner-operator has a driver record at
// drivers/{their own uid} (auto-created so "My Route" has an identity
// to read), AND may have manually added other drivers. In the picker
// these are just names. Assigning a route to the wrong same-named
// entry - or to any driver that isn't the owner's own uid record -
// means the owner's "My Route" (which reads drivers/{own uid}) shows
// "No route assigned" even though the route says "assigned". Marking
// the signed-in user's own record "(You)" and pinning it to the top
// makes "assign this to myself to test it" unambiguous, and dedupes
// in case a fetch and a listener both deliver the same driver.
enum DriverPickerOrdering {

    /// Deduped by id, with the signed-in user's own driver record (if
    /// any) first, then the rest alphabetically.
    static func ordered(_ drivers: [Driver]) -> [Driver] {
        let myUid = Auth.auth().currentUser?.uid
        var seen = Set<String>()
        let unique = drivers.filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            if a.id == myUid { return true }
            if b.id == myUid { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The name to show, tagging the signed-in user's own record so an
    /// owner-operator can tell which entry is themselves.
    static func label(for driver: Driver) -> String {
        driver.id == Auth.auth().currentUser?.uid ? "\(driver.name) (You)" : driver.name
    }
}
