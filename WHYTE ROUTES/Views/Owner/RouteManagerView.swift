//
//  RouteManagerView.swift
//  WHYTE ROUTES
//
//  Created by Hope Heaven on 2025-11-30.
//

import SwiftUI
import MapKit

struct RouteManagerView: View {
    
    @StateObject private var routeService = RouteService.shared
    
    @State private var selectedRoute: RouteTemplate?
    @State private var editingStops: [Stop] = []
    @State private var showingCreate = false
    @State private var newRouteName = ""
    @State private var isSaving = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                // HEADER
                Text("Route Manager")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                    .padding(.top, 40)
                
                Text("Create, edit and manage master routes")
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.bottom, 12)
                
                // ROUTE LIST
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(routeService.routeTemplates) { route in
                            routeRow(route)
                                .onTapGesture {
                                    selectedRoute = route
                                    editingStops = route.stops
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // ADD NEW ROUTE BUTTON
                GoldButton(title: "CREATE NEW ROUTE") {
                    showingCreate = true
                }
                .padding()
            }
            
            // EDITOR PANEL
            if let route = selectedRoute {
                routeEditor(route)
                    .transition(.move(edge: .bottom))
                    .animation(.spring(), value: selectedRoute)
            }
            
            if showingCreate {
                createRouteSheet
            }
            
            if isSaving {
                savingOverlay
            }
        }
    }
}
extension RouteManagerView {
    
    func routeRow(_ route: RouteTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name)
                        .foregroundColor(.white)
                        .font(.headline)
                    
                    Text("\(route.stops.count) stops")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.caption)
                }
                
                Spacer()
                
                Image(systemName: "map")
                    .foregroundColor(Color(hex: "#F5C451"))
                    .font(.title3)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(hex: "#F5C451").opacity(0.25), lineWidth: 1.5)
                )
        )
    }
}
extension RouteManagerView {
    
    @ViewBuilder
    func routeEditor(_ route: RouteTemplate) -> some View {
        
        VStack(spacing: 18) {
            
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 70, height: 6)
                .padding(.top, 8)
            
            Text("Editing: \(route.name)")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Divider().background(Color.white.opacity(0.2))
            
            // STOP LIST
            List {
                ForEach(editingStops.indices, id: \.self) { i in
                    stopRow(editingStops[i])
                }
                .onDelete { indexSet in
                    editingStops.remove(atOffsets: indexSet)
                }
                .onMove { indices, newOffset in
                    editingStops.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .listStyle(.insetGrouped)
            
            // ADD STOP BUTTON
            GoldButton(title: "ADD STOP") {
                addStop()
            }
            .padding(.horizontal)
            
            // SAVE + CLOSE BUTTONS
            HStack {
                GoldButton(title: "SAVE") {
                    saveRoute(route)
                }
                GoldButton(title: "CLOSE") {
                    selectedRoute = nil
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color(hex: "#F5C451").opacity(0.18), lineWidth: 1.5)
                )
        )
        .padding()
    }
}
extension RouteManagerView {
    
    func stopRow(_ stop: Stop) -> some View {
        HStack {
            Circle()
                .fill(Color(hex: "#F5C451"))
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading) {
                Text(stop.address)
                    .foregroundColor(.white)
                Text("Seq \(stop.sequence)")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.caption)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
extension RouteManagerView {
    
    func addStop() {
        let newStop = Stop(
            sequence: editingStops.count + 1,
            address: "New Address"
        )
        editingStops.append(newStop)
    }
}
extension RouteManagerView {
    
    func saveRoute(_ route: RouteTemplate) {
        isSaving = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            routeService.updateTemplate(routeId: route.id, stops: editingStops)
            isSaving = false
        }
    }
}
extension RouteManagerView {
    
    var createRouteSheet: some View {
        VStack(spacing: 20) {
            
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 70, height: 6)
                .padding(.top, 8)
            
            Text("Create New Route")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            TextField("Route Name", text: $newRouteName)
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(14)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            GoldButton(title: "CREATE") {
                routeService.createTemplate(name: newRouteName)
                newRouteName = ""
                showingCreate = false
            }
            
            GoldButton(title: "CANCEL") {
                showingCreate = false
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.black.opacity(0.92))
        )
        .padding()
    }
}
extension RouteManagerView {
    
    var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            ProgressView("Saving Route…")
                .tint(Color(hex: "#F5C451"))
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(14)
        }
    }
}
