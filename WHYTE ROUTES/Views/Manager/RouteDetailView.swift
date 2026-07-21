import SwiftUI
import FirebaseFirestore

struct RouteDetailView: View {
    
    let route: Route
    @State private var stops: [Stop] = []
    @State private var generatedLink: String = ""
    @State private var showShareSheet = false
    
    // Fetch selected driver (you can change based on your app)
    @State private var selectedDriver: Driver?
    
    var body: some View {
        ZStack {
            AppTheme.black.ignoresSafeArea()
            VStack {
                
                // MARK: - Stop List
                List(stops) { stop in
                    VStack(alignment: .leading) {
                        Text(stop.address)
                            .font(.headline)
                            .foregroundColor(AppTheme.textPrimary)
                        Text("Order: \(stop.sequence)")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                
                // MARK: - Assign Driver
                NavigationLink {
                    AssignRouteView(routeId: route.id ?? "")
                } label: {
                    Text("Assign Driver").bold()
                }
                .buttonStyle(GoldButton())
                
                // MARK: - Generate Tracking Link Button
                if let driver = selectedDriver,
                   let firstStop = stops.first {
                    
                    Button(action: {
                        generateTrackingLink(driver: driver, firstStop: firstStop)
                    }) {
                        HStack {
                            Image(systemName: "link.circle.fill")
                            Text("Generate Tracking Link").bold()
                        }
                        .foregroundColor(AppTheme.gold)
                    }
                    .buttonStyle(GoldButton())
                    .sheet(isPresented: $showShareSheet) {
                        ActivityView(activityItems: [generatedLink])
                    }
                    
                } else {
                    Text("Assign a driver to generate tracking")
                        .foregroundColor(AppTheme.textSecondary)
                }
                
                // MARK: - Optimize Route Button
                Button("Optimize Route") {
                    optimize()
                }
                .buttonStyle(GoldButton())
            }
            .tint(AppTheme.gold)
        }
        .onAppear {
            loadStops()
            loadAssignedDriver()
        }
        .navigationTitle("Route Details")
    }
    
    // MARK: Load Stops
    func loadStops() {
        Firestore.firestore()
            .collection("stops")
            .whereField("routeId", isEqualTo: route.id ?? "")
            .order(by: "sequence")
            .addSnapshotListener { snapshot, _ in
                stops = snapshot?.documents.compactMap {
                    try? $0.data(as: Stop.self)
                } ?? []
            }
    }
    
    // MARK: Load Assigned Driver
    func loadAssignedDriver() {
        // TODO: Replace with your driver assignment logic
        // For now we mock:
        self.selectedDriver = DriverSession.shared.currentDriver
    }
    
    // MARK: Generate Tracking Link
    func generateTrackingLink(driver: Driver, firstStop: Stop) {
        
        RouteService.shared.generateLinkForStop(
            route: route,
            stop: firstStop,
            driver: driver
        ) { link in
            
            if let link = link {
                generatedLink = link
                showShareSheet = true
                
                // Auto start GPS for driver
                LocationService.shared.startTracking(
                    driverId: driver.id,
                    stopLat: firstStop.latitude!,
                    stopLng: firstStop.longitude!
                )
                
                // Auto send SMS
                if let phone = firstStop.customerPhone {
                    sendSMSToCustomer(phone: phone, link: link)
                }
            }
        }
    }
    
    func optimize() {
        // Your route optimizer
    }
}
