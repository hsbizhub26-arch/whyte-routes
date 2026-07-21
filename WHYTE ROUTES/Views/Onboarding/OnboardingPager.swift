import SwiftUI

struct OnboardingPager: View {
    
    @State private var index = 0
    
    var body: some View {
        TabView(selection: $index) {
            
            OnboardingSlide(
                title: "Whyte Routes",
                subtitle: "Premium fleet management for real businesses.",
                image: "onboard_map"
            )
            .tag(0)
            
            OnboardingSlide(
                title: "Track Drivers",
                subtitle: "Live GPS, route progress, and ETAs for all customers.",
                image: "onboard_driver"
            )
            .tag(1)
            
            OnboardingSlide(
                title: "Optimize Routes",
                subtitle: "Faster routes. Lower cost. Higher efficiency.",
                image: "onboard_optimize"
            )
            .tag(2)
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(WRTheme.gold)
            UIPageControl.appearance().pageIndicatorTintColor = UIColor.gray
        }
        .fullScreenCover(isPresented: .constant(index == 3)) {
            RoleSelectionView()
        }
        .onChange(of: index) {
            if index == 3 { }
        }
    }
}
