import Foundation

// B4: turns text read off a photo (a business card, a signed contract,
// a sticky note from the truck) into suggested customer fields.
//
// Pre-fill ONLY: every value lands in the normal Add Customer form for
// the owner to check. Nothing is saved from here, the phone still goes
// through PhoneNumber.check on save, and the address must still be
// picked from the suggestions so it gets real coordinates.
struct ScannedContact: Equatable {
    var name: String?
    var phone: String?
    var email: String?
    var address: String?

    var isEmpty: Bool { name == nil && phone == nil && email == nil && address == nil }
}

enum ContactTextParser {

    static func parse(lines rawLines: [String]) -> ScannedContact {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        var result = ScannedContact()

        // Email: a plain pattern beats NSDataDetector's link type here,
        // which also matches websites.
        if let r = text.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
            result.email = String(text[r]).lowercased()
        }

        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address]
        let detector = try? NSDataDetector(types: types.rawValue)
        let ns = text as NSString
        var addressLines: Set<String> = []
        detector?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let found = ns.substring(with: match.range)
            switch match.resultType {
            case .phoneNumber:
                // Prefer a North American-length number; first one wins.
                let digits = found.filter(\.isNumber)
                if result.phone == nil, digits.count >= 10, digits.count <= 11 {
                    result.phone = found.trimmingCharacters(in: .whitespaces)
                }
            case .address:
                if result.address == nil {
                    result.address = found.replacingOccurrences(of: "\n", with: ", ")
                    found.split(separator: "\n").forEach { addressLines.insert(String($0).trimmingCharacters(in: .whitespaces)) }
                }
            default: break
            }
        }

        // Fallback street-address shape for when the detector misses
        // ("12 Maple Cres"): number + words + a street type.
        if result.address == nil,
           let line = lines.first(where: { $0.range(of: #"^\d{1,6}\s+[A-Za-z0-9.' ]+\b(St|Street|Rd|Road|Ave|Avenue|Dr|Drive|Cres|Crescent|Crt|Court|Ct|Blvd|Way|Lane|Ln|Pl|Place|Trail|Trl|Cir|Circle|Gate|Hwy|Pkwy)\b\.?"#,
                                                         options: [.regularExpression, .caseInsensitive]) != nil }) {
            result.address = line
            addressLines.insert(line)
        }

        // Name: an explicit "Name:" label wins; otherwise the first line
        // that looks like a person's name and isn't one of the above.
        if let labelled = lines.lazy.compactMap({ line -> String? in
            guard let r = line.range(of: #"^(customer\s+)?name\s*[:\-]\s*"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }).first {
            result.name = labelled
        } else {
            result.name = lines.first { line in
                guard !addressLines.contains(line),
                      line.range(of: #"[@\d]"#, options: .regularExpression) == nil,
                      line.range(of: #"\b(inc|ltd|llc|corp|landscap|snow|services?|contract|invoice|agreement|season|www|http|tel|phone|email|fax|address)\b"#,
                                 options: [.regularExpression, .caseInsensitive]) == nil else { return false }
                let words = line.split(separator: " ")
                return (2...4).contains(words.count)
                    && words.allSatisfy { $0.first?.isLetter == true && $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." } }
            }
        }
        return result
    }
}
