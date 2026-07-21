import SwiftUI

struct OnboardingSlide: View {
    
    var title: String
    var subtitle: String
    var image: String
    
    var body: some View {
        ZStack {
            WRTheme.gradient.ignoresSafeArea()
            
            VStack(spacing: 40) {
                
                Spacer()
                
                Image(image) // add PNGs to Assets
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .shadow(color: WRTheme.gold.opacity(0.4), radius: 20)
                
                VStack(spacing: 10) {
                    Text(title)
                        .foregroundColor(WRTheme.gold)
                        .font(.largeTitle.bold())
                    
                    Text(subtitle)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .font(.headline)
                        .padding(.horizontal, 30)
                }
                
                Spacer()
                
                GoldButton(title: "CONTINUE") {
                    // parent increments index
                    NextSlideEvent.trigger()
                }
                .padding(.bottom, 60)
                .padding(.horizontal)
            }
        }
    }
}
