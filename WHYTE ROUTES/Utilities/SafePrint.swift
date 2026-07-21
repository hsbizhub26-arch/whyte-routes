import Foundation

func safePrint(_ items: Any...) {
    #if DEBUG
    for item in items {
        print("[WR DEBUG]:", item)
    }
    #endif
}
