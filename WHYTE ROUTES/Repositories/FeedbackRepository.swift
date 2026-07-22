import Foundation
import FirebaseFirestore

final class FeedbackRepository {

    private let db = Firestore.firestore()

    func submit(_ report: FeedbackReport, completion: ((Bool) -> Void)? = nil) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ FeedbackRepository: no current company set - cannot submit feedback")
            completion?(false)
            return
        }

        db.collection("companies").document(companyId)
            .collection("feedback").document(report.id)
            .setData(report.toDict()) { error in
                if let error {
                    print("⚠️ FeedbackRepository.submit failed: \(error.localizedDescription)")
                }
                completion?(error == nil)
            }
    }
}
