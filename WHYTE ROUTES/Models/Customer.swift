import Foundation
import FirebaseFirestore

struct Customer: Identifiable {
    var id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var phone: String? = nil
    var email: String? = nil
    // Standing instructions for whoever's servicing this property -
    // gate codes, "no scrape the driveway", dog in the yard, where to
    // park. Shown to the driver on the stop itself (see
    // DriverStopView), not just filed away on the customer record.
    var notes: String? = nil
    // Defaults false - nobody is notified without explicitly agreeing
    // first. This is now the SOURCE OF TRUTH once a stop is linked to
    // this record via Stop.customerId (see NotificationService) - the
    // copy still carried on Stop itself is only a fallback for stops
    // created before this record existed or that were never linked.
    var notificationsOptIn: Bool = false
    // Set the moment notificationsOptIn first flips true (see
    // AddCustomerView) - proof of *when* consent was given, not just
    // that it currently is, for CASL record-keeping. Never cleared
    // once set, even if opt-in is later turned off, so a dispute can
    // still be answered with "consented on X, withdrawn on Y" instead
    // of losing the original date.
    var consentTimestamp: Date? = nil
    // Per-channel and per-type preferences, all default true so an
    // existing opted-in customer keeps getting everything they always
    // got - these only narrow what notificationsOptIn already allows,
    // never widen it. The Cloud Function checks notificationsOptIn
    // first as the master gate, then these for which channel/type.
    var smsEnabled: Bool = true
    var emailEnabled: Bool = true
    // The two ETA pings default OFF; enRoute/arrived/completed already
    // cover the journey. With all five on, one stop sends five texts -
    // "on the way", "15 min", "10 min", "arrived", "completed" - which
    // is both more than anyone needs at 3am and a real cost: at
    // $0.0079 a segment, a busy Premium company running 150 stops a day
    // spends more on Twilio than the $64.99 they pay us. Three texts
    // per stop keeps the useful ones and the margin.
    //
    // Still per-customer toggles in Add Customer, so an owner who wants
    // the countdown for a particular client can switch it back on.
    var notifyEta15: Bool = false
    var notifyEta10: Bool = false
    var notifyCompleted: Bool = true
}

// MARK: - Firestore Decode
extension Customer {
    init?(from dict: [String: Any], id: String) {
        guard let name = dict["name"] as? String,
              let address = dict["address"] as? String,
              let latitude = dict["latitude"] as? Double,
              let longitude = dict["longitude"] as? Double else {
            return nil
        }

        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.phone = dict["phone"] as? String
        self.email = dict["email"] as? String
        self.notes = dict["notes"] as? String
        self.notificationsOptIn = dict["notificationsOptIn"] as? Bool ?? false
        self.consentTimestamp = (dict["consentTimestamp"] as? Timestamp)?.dateValue()
        self.smsEnabled = dict["smsEnabled"] as? Bool ?? true
        self.emailEnabled = dict["emailEnabled"] as? Bool ?? true
        // Existing customers who explicitly have these set to true keep
        // them - this only changes what a customer created from now on,
        // and what a document missing the field decodes to.
        self.notifyEta15 = dict["notifyEta15"] as? Bool ?? false
        self.notifyEta10 = dict["notifyEta10"] as? Bool ?? false
        self.notifyCompleted = dict["notifyCompleted"] as? Bool ?? true
    }

    // MARK: - Encode
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "name": name,
            "address": address,
            "latitude": latitude,
            "longitude": longitude,
            "notificationsOptIn": notificationsOptIn,
            "smsEnabled": smsEnabled,
            "emailEnabled": emailEnabled,
            "notifyEta15": notifyEta15,
            "notifyEta10": notifyEta10,
            "notifyCompleted": notifyCompleted
        ]
        if let phone { d["phone"] = phone }
        if let email { d["email"] = email }
        if let notes { d["notes"] = notes }
        if let consentTimestamp { d["consentTimestamp"] = Timestamp(date: consentTimestamp) }
        return d
    }
}
