//
//  DriverShiftReportView.swift
//  WHYTE ROUTES
//
//  Created by Hope Heaven on 2025.
//

import SwiftUI
import FirebaseFirestore

struct DriverShiftReportView: View {

    @ObservedObject private var session = DriverSession.shared
    @ObservedObject private var nextStopController = DriverNextStopController.shared
    @ObservedObject private var timer = TimerService.shared

    @State private var submitting = false
    @State private var submitted = false

    private let db = Firestore.firestore()

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 24) {

                header

                Divider().overlay(Color("WRThemeGold"))

                if submitted {
                    successView
                } else {
                    scrollContent
                    submitButton
                }

                Spacer()
            }
            .padding()
        }
        .onAppear { timer.stop() }
    }

    // MARK: - HEADER
    private var header: some View {
        VStack(spacing: 6) {
            Text("Shift Report")
                .foregroundColor(Color("WRThemeGold"))
                .font(.largeTitle.bold())

            Text("Review and submit your shift details")
                .foregroundColor(.white.opacity(0.7))
                .font(.subheadline)
        }
    }

    // MARK: - MAIN CONTENT
    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 20) {

                if let driver = session.driver {
                    infoRow(title: "Driver", value: driver.name)
                }

                if let route = session.assignedRoute {
                    infoRow(title: "Route", value: route.name)
                }

                infoRow(title: "Completed Stops", value: "\(completedStops.count)")
                infoRow(title: "Skipped Stops", value: "\(skippedStops.count)")
                infoRow(title: "Total Stops", value: "\(totalStops)")
                infoRow(title: "Shift Duration", value: formatSeconds(timer.seconds))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Completed Stops")
                        .foregroundColor(Color("WRThemeGold"))
                        .font(.headline)

                    ForEach(completedStops) { stop in
                        Text("• \(stop.customerName ?? "") – \(stop.address)")
                            .foregroundColor(.white.opacity(0.9))
                            .font(.subheadline)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.25))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - DATA EXTRACTORS
    private var completedStops: [Stop] {
        nextStopController.remainingStops.filter { $0.isCompleted }
    }

    private var skippedStops: [Stop] {
        nextStopController.remainingStops.filter { $0.isSkipped }
    }

    private var totalStops: Int {
        nextStopController.remainingStops.count
    }

    // MARK: - SUBMIT BUTTON
    private var submitButton: some View {
        Button {
            submitReport()
        } label: {
            if submitting {
                ProgressView().tint(Color("WRThemeGold"))
            } else {
                Text("Submit Report")
                    .foregroundColor(.black)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color("WRThemeGold"))
                    .cornerRadius(14)
            }
        }
        .disabled(submitting)
        .padding(.top, 10)
    }

    // MARK: - SUCCESS VIEW
    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Shift Report Submitted")
                .foregroundColor(.white)
                .font(.title2.bold())

            Text("Thank you for your work today!")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.top, 40)
    }

    // MARK: - UTILS
    func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(Color("WRThemeGold"))
                .font(.headline)

            Spacer()

            Text(value)
                .foregroundColor(.white)
        }
    }

    func formatSeconds(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h \(m)m"
    }

    // MARK: - FIRESTORE SAVE
    func submitReport() {
        guard let driver = session.driver else { return }

        submitting = true

        let doc = db.collection("driverReports")
            .document(driver.id)
            .collection("reports")
            .document()

        let data: [String: Any] = [
            "driverId": driver.id,
            "driverName": driver.name,
            "vehicle": driver.vehicle,
            "routeId": session.assignedRoute?.id ?? "",
            "routeName": session.assignedRoute?.name ?? "",
            "completedStops": completedStops.map { $0.address },
            "skippedStops": skippedStops.map { $0.address },
            "totalStops": totalStops,
            "shiftDurationSec": timer.seconds,
            "submittedAt": FieldValue.serverTimestamp()
        ]

        doc.setData(data) { error in
            submitting = false
            submitted = (error == nil)
        }
    }
}
