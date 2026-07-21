//
//  DashboardView.swift
//  WHYTE ROUTES
//
//  Created by Hope Heaven on 2025-11-30.
//

import SwiftUI
import MapKit

struct DashboardView: View {
    
    @StateObject private var driverService = DriverService.shared
    @StateObject private var routeService = RouteService.shared
    @StateObject private var locationService = LocationService.shared
    
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.44),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )
    
    @State private var selectedDriver: Driver? = nil
    
    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                // ------------------------------------------------------------
                // TOP: LIVE DRIVER MAP (ADMIN VIEW)
                // ------------------------------------------------------------
                ZStack {
                    Map(
                        coordinateRegion: $region,
                        annotationItems: driverService.activeDrivers
                    ) { driver in
                        MapAnnotation(coordinate: driver.location.coordinate) {
                            DriverPin(driver: driver)
                                .onTapGesture {
                                    selectedDriver = driver
                                }
                        }
                    }
                    .frame(height: UIScreen.main.bounds.height * 0.45)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color("WRThemeGold").opacity(0.15), lineWidth: 2)
                    )
                    .shadow(color: Color(hex: "#F5C451").opacity(0.25), radius: 10)
                    
                    VStack {
                        HStack {
                            Text("WHYTEROUTES ADMIN")
                                .foregroundColor(.white)
                                .font(.headline)
                                .padding(8)
                                .background(Color("WRDeepBlack").opacity(0.6))
                                .clipShape(Capsule())
                                .shadow(radius: 6)
                            
                            Spacer()
                        }.padding()
                        Spacer()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
                
                Spacer(minLength: 12)
                
                // ------------------------------------------------------------
                // DRIVER SELECTION SHEET (SLIDING CARD)
                // ------------------------------------------------------------
                if let driver = selectedDriver {
                    DriverDetailSheet(driver: driver) {
                        selectedDriver = nil
                    }
                    .transition(.move(edge: .bottom))
                    .animation(.spring(), value: selectedDriver)
                }
                
                // ------------------------------------------------------------
                // ACTION PANEL (BUTTON GRID)
                // ------------------------------------------------------------
                VStack(spacing: 22) {
                    
                    Text("Management Tools")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.title3)
                        .bold()
                        .padding(.top, 4)
                    
                    HStack(spacing: 14) {
                        ActionCard(title: "Assign Routes", icon: "arrow.triangle.2.circlepath") {
                            routeService.openAssignRoutes()
                        }
                        ActionCard(title: "Customers", icon: "person.3") {
                            routeService.openCustomerList()
                        }
                    }
                    
                    HStack(spacing: 14) {
                        ActionCard(title: "Driver Reports", icon: "doc.text.magnifyingglass") {
                            routeService.openDriverReports()
                        }
                        ActionCard(title: "Route Manager", icon: "map") {
                            routeService.openRouteManager()
                        }
                    }
                }
                .padding()
                .wrPanel()
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
        }
    }
}
