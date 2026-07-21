import Foundation
import MessageUI
import UIKit

/// Handles sending SMS messages (in-app composer or URL fallback).
final class SMSService: NSObject, MFMessageComposeViewControllerDelegate {

    static let shared = SMSService()

    private override init() {}

    // MARK: - Public API

    func sendSMS(phone: String,
                 link: String,
                 driverName: String? = nil,
                 etaMinutes: Int? = nil) {

        let body = buildMessageBody(link: link, driverName: driverName, eta: etaMinutes)

        // In-app composer
        if MFMessageComposeViewController.canSendText() {
            presentInAppSMS(recipients: [phone], body: body)
            return
        }

        // Fallback:
        openURLSMS(phone: phone, body: body)
    }

    // MARK: - Build SMS Body

    private func buildMessageBody(link: String,
                                  driverName: String?,
                                  eta: Int?) -> String {

        if let name = driverName {
            var body = "Your driver \(name) is on the way. "
            if let eta = eta {
                body += "Estimated arrival in \(eta) minutes. "
            }
            body += "Track their progress here: \(link)"
            return body
        }

        return "Your service is on the way. Track progress: \(link)"
    }

    // MARK: - In-App SMS

    private func presentInAppSMS(recipients: [String], body: String) {
        let composer = MFMessageComposeViewController()
        composer.body = body
        composer.recipients = recipients
        composer.messageComposeDelegate = self

        if let vc = topViewController() {
            vc.present(composer, animated: true)
        }
    }

    // Close composer
    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
    }

    // MARK: - URL Fallback

    private func openURLSMS(phone: String, body: String) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#%")

        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
        let urlString = "sms:\(phone)?&body=\(encodedBody)"

        if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - View Controller Helper

    private func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first?.rootViewController) -> UIViewController? {

        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
