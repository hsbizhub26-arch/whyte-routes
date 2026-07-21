import SwiftUI

struct SplashView: View {
    
    @State private var fadeIn = false
    @State private var scaleUp = false
    @State private var finished = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            RadialGradient(colors: [WRTheme.gold.opacity(0.25), .clear], center: .center, startRadius: 10, endRadius: 380)
                .blendMode(.screen)
                .ignoresSafeArea()
            
            VStack {
                Image("whyteroutes_logo")   // ADD TO ASSETS
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180)
                    .scaleEffect(scaleUp ? 1.0 : 0.6)
                    .opacity(fadeIn ? 1 : 0)
                    .shadow(color: WRTheme.gold.opacity(0.7), radius: 30, x: 0, y: 10)
            }
            
            Circle()
                .strokeBorder(WRTheme.gold.opacity(0.25), lineWidth: 2)
                .frame(width: 260, height: 260)
                .scaleEffect(scaleUp ? 1.05 : 0.85)
                .animation(.easeOut(duration: 1.2), value: scaleUp)
        }
        .onAppear { animate() }
        .fullScreenCover(isPresented: $finished) {
            OnboardingPager()
        }
    }
    
    func animate() {
        withAnimation(.easeOut(duration: 1.2)) {
            fadeIn = true
            scaleUp = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            finished = true
        }
    }
}
