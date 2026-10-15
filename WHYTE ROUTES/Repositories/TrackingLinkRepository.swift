import Foundation
import FirebaseFirestore

final class TrackingLinkRepository {

    private let db = Firestore.firestore()

    /// Tracking links for a specific company - explicit companyId
    /// parameter (not read from CompanySession) because listenTo is
    /// called from the unauthenticated customer tracking screen, which
    /// has no signed-in session and therefore no CompanySession state.
    /// Staff-only methods (create/deactivate) use the signed-in user's
    /// current company instead.
    private func trackingLinksRef(companyId: String) -> CollectionReference {
        db.collection("companies").document(companyId).collection("trackingLinks")
    }

    // MARK: - Create Tracking Link (staff, authenticated)
    func create(
        customerName: String,
        address: String,
        driverId: String,
        stopId: String,
        // Required, not optional-with-a-default, on purpose: a link
        // written without it can never be matched to the customer it
        // was minted for, so every future identity check has to treat
        // it as somebody else's and supersede it. Pass the stop's
        // customerId - explicitly nil is fine for a one-off stop with
        // no Customer record, but it should be a decision, not an
        // omission.
        customerId: String?,
        stopLatitude: Double? = nil,
        stopLongitude: Double? = nil,
        completion: @escaping (TrackingLink?) -> Void
    ) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ TrackingLinkRepository: no current company set - cannot create link")
            completion(nil)
            return
        }

        let doc = trackingLinksRef(companyId: companyId).document()

        var data: [String: Any] = [
            "customerName": customerName,
            "address": address,
            "stopId": stopId,
            "active": true,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let customerId { data["customerId"] = customerId }
        if let stopLatitude { data["stopLatitude"] = stopLatitude }
        if let stopLongitude { data["stopLongitude"] = stopLongitude }

        doc.setData(data) { error in
            if let error = error {
                print("❌ Failed to create tracking link:", error.localizedDescription)
                completion(nil)
                return
            }

            // Re-fetch the document so we get the real server timestamp
            doc.getDocument { snap, _ in
                guard let snap = snap,
                      let fullData = snap.data(),
                      let link = TrackingLink(from: fullData, id: snap.documentID, companyId: companyId)
                else {
                    completion(nil)
                    return
                }

                completion(link)
            }
        }
    }

    // MARK: - Publish Live Position (driver, authenticated)
    // Writes ONLY a coordinate and an ETA - deliberately never the
    // driver's name, phone or id. This one document is world-readable
    // by anyone holding the link (see firestore.rules), so anything
    // written here is effectively public and must stay non-identifying.
    //
    // Always the same document id ("current"), so the customer's page
    // can listen to a known path and the collection can't grow a new
    // document per GPS ping.
    func publishLocation(
        companyId: String,
        linkId: String,
        latitude: Double?,
        longitude: Double?,
        heading: Double? = nil,
        stopsBefore: Int? = nil,
        isCurrentDestination: Bool? = nil,
        hasArrived: Bool? = nil,
        etaMinutes: Int?
    ) {
        var data: [String: Any] = [
            "updatedAt": FieldValue.serverTimestamp()
        ]

        // Coordinates are ACTIVELY REMOVED, not merely omitted, for a
        // customer who isn't the current destination. These writes use
        // merge, so leaving them out would preserve whatever was there
        // before - the exact stale position that would let a waiting
        // customer read the truck's location at another property.
        if let latitude, let longitude {
            data["latitude"] = latitude
            data["longitude"] = longitude
        } else {
            data["latitude"] = FieldValue.delete()
            data["longitude"] = FieldValue.delete()
        }

        if let heading {
            data["heading"] = heading
        } else {
            data["heading"] = FieldValue.delete()
        }
        // A COUNT of the stops ahead of this customer - never anything
        // identifying about them. This is what lets the page say
        // "2 stops before yours" without the customer's page ever
        // being able to read another customer's record.
        if let stopsBefore { data["stopsBefore"] = stopsBefore }
        if let isCurrentDestination { data["isCurrentDestination"] = isCurrentDestination }
        // Purely a status flag - lets the customer's page say "your
        // driver is here" instead of insisting they're still on the
        // way while the truck sits in their driveway.
        if let hasArrived { data["hasArrived"] = hasArrived }
        if let etaMinutes {
            data["etaMinutes"] = etaMinutes
        } else {
            data["etaMinutes"] = FieldValue.delete()
        }

        trackingLinksRef(companyId: companyId)
            .document(linkId)
            .collection("location")
            .document("current")
            .setData(data, merge: true)
    }

    /// Every still-active link pointed at a stop. Usually one, but a
    /// stop that has been re-pointed at a different customer can have
    /// the superseded customer's link sitting alongside the current
    /// one, and the tear-down paths need to see both.
    private func activeLinks(forStopId stopId: String, completion: @escaping ([TrackingLink]) -> Void) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            completion([])
            return
        }
        trackingLinksRef(companyId: companyId)
            .whereField("stopId", isEqualTo: stopId)
            .whereField("active", isEqualTo: true)
            .getDocuments { snap, error in
                guard error == nil, let docs = snap?.documents else {
                    // Distinguishable in the log from a genuine empty
                    // result. Both still yield [], because retrying a
                    // teardown automatically risks racing a re-mint,
                    // but a failure to close a customer's live tracking
                    // must not be silent.
                    if let error {
                        print("❌ activeLinks(stop \(stopId)) failed - links may still be live: \(error.localizedDescription)")
                    }
                    completion([])
                    return
                }
                completion(docs.compactMap {
                    TrackingLink(from: $0.data(), id: $0.documentID, companyId: companyId)
                })
            }
    }

    /// The live link belonging to the customer this stop points at
    /// RIGHT NOW. Used by the driver's app to know whether someone is
    /// actually watching before it starts publishing position.
    ///
    /// Takes the whole stop, not just its id, because the id alone is
    /// not enough to answer the question. Staff can re-point a stop at
    /// a different customer without its id changing, and looking up
    /// "the active link for this stop" would then hand back the
    /// PREVIOUS customer's link - which the broadcaster would happily
    /// stream the truck's position into, all the way to and including
    /// parked in the new customer's driveway, while that page still
    /// showed the old customer their own name and address. Any link
    /// that doesn't belong to the current customer is not returned, so
    /// nothing downstream can publish into it.
    func activeLink(for stop: Stop, completion: @escaping (TrackingLink?) -> Void) {
        activeLinks(forStopId: stop.id) { links in
            completion(links.first { $0.belongsTo(stop) })
        }
    }

    // MARK: - Close Out a Stop's Tracking Link
    // Called the moment a stop is completed. Deletes the live position
    // document FIRST, then marks the link inactive.
    //
    // Deleting rather than merely flagging is the point: that document
    // is world-readable to anyone holding the link, so a customer whose
    // own service is finished must not be able to keep watching the
    // truck drive on to other people's homes for the rest of the shift.
    // Hiding it in the page would leave the data sitting there for
    // anyone who opened a console; removing it means there is nothing
    // left to read. The page's "Service complete" state then comes from
    // the link's own active/completed flags.
    // Closes EVERY still-active link on the stop, not just the one
    // belonging to the current customer. If staff re-pointed this stop
    // partway through the day, a previous customer's link can still be
    // sitting there active with a last-known position in it; finishing
    // the job is the right moment for all of them to go dark, and
    // "close the one that matches" would leave that one alive until
    // the rules' 24h window eventually expired it.
    //
    // Already-superseded links are excluded automatically - they were
    // set active:false when they were superseded, so the query doesn't
    // see them, and they must NOT be given a completedAt here: that
    // would open a fresh 2h read window for a customer this stop no
    // longer belongs to.
    func closeOut(stopId: String) {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }

        // STRONG capture, deliberately, and not a retain cycle.
        //
        // A cycle needs repo -> closure -> repo. This class is a final
        // class with NO stored properties: it never holds a listener,
        // a closure or any other reference. activeLinks hands the
        // closure to Firestore's one-shot getDocuments, Firestore owns
        // it until it fires, and releases it afterwards - so the only
        // reference chain is Firestore -> closure -> repo, which
        // unwinds on its own the moment the callback returns.
        //
        // [weak self] here was therefore protecting against nothing
        // while creating a real failure: the caller's repository could
        // die before the query came back, self would be nil, and the
        // links were left ACTIVE. Whether a customer stops seeing the
        // driver must not depend on whether the driver happened to
        // stay on the stop screen long enough.
        activeLinks(forStopId: stopId) { links in
            for link in links {
                self.goDark(
                    companyId: companyId,
                    linkId: link.id,
                    context: "stop \(stopId)",
                    fields: [
                        "active": false,
                        "completed": true,
                        "completedAt": FieldValue.serverTimestamp()
                    ]
                )
            }
        }
    }

    // MARK: - Close a Skipped Stop's Links
    // The driver passed this stop without servicing it. Unlike closeOut
    // this sets neither `completed` nor `completedAt`: the customer must
    // not be told "Service complete" for a visit that never happened.
    // With active:false and no completedAt the rule denies the read and
    // the page falls to its "no longer available" state.
    func closeOutSkipped(stopId: String) {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }

        activeLinks(forStopId: stopId) { links in
            for link in links {
                self.goDark(
                    companyId: companyId,
                    linkId: link.id,
                    context: "skipped stop \(stopId)",
                    fields: ["active": false]
                )
            }
        }
    }

    // MARK: - Supersede a Stop's Links (staff re-pointed the stop)
    // Called when a stop stops meaning the person its links were minted
    // for - the owner's "Change Customer" picker. Everything that was
    // live for the old customer is torn down immediately.
    //
    // Deliberately does NOT set completedAt, unlike closeOut. The
    // security rule keeps a link readable for two hours after
    // completion so the customer's page can show that their service
    // finished; a superseded customer is owed no such window, and the
    // page it powers is showing them a name and address that are about
    // to belong to somebody else. With active:false and no
    // completedAt the rule denies the read on the spot and the page
    // falls to its "this link is no longer available" state.
    func supersedeLinks(forStopId stopId: String) {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }

        // STRONG capture, deliberately, and not a retain cycle.
        //
        // A cycle needs repo -> closure -> repo. This class is a final
        // class with NO stored properties: it never holds a listener,
        // a closure or any other reference. activeLinks hands the
        // closure to Firestore's one-shot getDocuments, Firestore owns
        // it until it fires, and releases it afterwards - so the only
        // reference chain is Firestore -> closure -> repo, which
        // unwinds on its own the moment the callback returns.
        //
        // [weak self] here was therefore protecting against nothing
        // while creating a real failure: the caller's repository could
        // die before the query came back, self would be nil, and the
        // links were left ACTIVE. Whether a customer stops seeing the
        // driver must not depend on whether the driver happened to
        // stay on the stop screen long enough.
        activeLinks(forStopId: stopId) { links in
            for link in links {
                self.goDark(
                    companyId: companyId,
                    linkId: link.id,
                    context: "superseded stop \(stopId)",
                    fields: [
                        "active": false,
                        "superseded": true,
                        "supersededAt": FieldValue.serverTimestamp()
                    ]
                )
            }
        }
    }

    /// Deletes the live position first, then flags the link. Deleting
    /// rather than merely flagging is the point: that document is
    /// world-readable to anyone holding the link, so hiding it in the
    /// page would leave the coordinates sitting there for anyone who
    /// opened a console. Removing it means there is nothing to read.
    ///
    /// The flag is written whether or not the delete succeeded - a
    /// failed delete must not additionally leave the page looking
    /// permanently live.
    private func goDark(companyId: String,
                        linkId: String,
                        context: String,
                        fields: [String: Any]) {
        let linkRef = trackingLinksRef(companyId: companyId).document(linkId)
        linkRef.collection("location").document("current").delete { error in
            if let error {
                print("\u{26a0}\u{fe0f} Couldn't delete tracking position for \(context): \(error.localizedDescription)")
            }
            linkRef.updateData(fields)
        }
    }

    // MARK: - Deactivate Link (staff, authenticated)
    func deactivate(id: String) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ TrackingLinkRepository: no current company set - cannot deactivate link")
            return
        }

        trackingLinksRef(companyId: companyId)
            .document(id)
            .updateData([
                "active": false,
                "completed": true,
                "completedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Listen to a Tracking Link (unauthenticated Customer Tracking View)
    func listenTo(companyId: String, linkId: String, handler: @escaping (TrackingLink?) -> Void) {
        trackingLinksRef(companyId: companyId)
            .document(linkId)
            .addSnapshotListener { snap, error in

                if let error = error {
                    print("❌ Failed listening to tracking link:", error.localizedDescription)
                    handler(nil)
                    return
                }

                guard let snap = snap, let data = snap.data() else {
                    handler(nil)
                    return
                }

                handler(TrackingLink(from: data, id: snap.documentID, companyId: companyId))
            }
    }
}
