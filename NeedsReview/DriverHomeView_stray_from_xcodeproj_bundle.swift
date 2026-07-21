import SwiftUI

struct DriverHomeView: View {
    let driver: AppDriver

    init(driver: AppDriver) {
        self.driver = driver
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Hello, \(driver.name)")
                    .font(.title.bold())
                NavigationLink("View My Route") {
                    DriverRouteView(driver: driver)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Driver")
        }
    }
}

struct DriverRouteView: View {
    let driver: AppDriver

    var body: some View {
        Text("DriverRouteView Placeholder")
    }
}

#Preview {
    DriverHomeView(driver: AppDriver(from: ["name": "Preview"], id: "demo")!)
}
