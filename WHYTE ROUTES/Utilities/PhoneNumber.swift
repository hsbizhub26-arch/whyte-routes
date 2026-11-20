import Foundation

/// Phone numbers for customer texts, stored in E.164 ("+16475550100").
///
/// The same rules as toE164 in functions/index.js, so the app and the
/// server agree on what a valid number is:
///  - "+" followed by 8-15 digits is trusted as international;
///  - otherwise only North American shapes are inferred: 10 digits, or
///    11 starting with 1, with area code and exchange starting 2-9.
/// An empty entry is NOT an error - many customers have no mobile on file.
enum PhoneNumber {

    enum Result: Equatable {
        case empty
        case valid(String)   // E.164
        case invalid
    }

    static func check(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let isInternational = trimmed.hasPrefix("+")
        let digits = trimmed.filter(\.isNumber)
        if isInternational {
            return (8...15).contains(digits.count) ? .valid("+" + digits) : .invalid
        }
        let nanp: String
        if digits.count == 11, digits.hasPrefix("1") { nanp = String(digits.dropFirst()) }
        else if digits.count == 10 { nanp = digits }
        else { return .invalid }
        let chars = Array(nanp)
        guard let a = chars.first, let e = chars.dropFirst(3).first,
              ("2"..."9").contains(a), ("2"..."9").contains(e) else { return .invalid }
        return .valid("+1" + nanp)
    }

    static let invalidMessage =
        "That phone number doesn't look right. Use 10 digits like 647-555-0100, or +country code for numbers outside North America. Leave it blank if there's no mobile."
}
