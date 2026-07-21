import SwiftUI

struct GoldPulse: ViewModifier {
    
    @State private var pulse = false
    
    func body(content: Content) -> some View {
        content
            .shadow(color: WRTheme.gold.opacity(pulse ? 0.7 : 0.2),
                    radius: pulse ? 20 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever()) {
                    pulse.toggle()
                }
            }
    }
}

extension View {
    func goldPulse() -> some View {
        self.modifier(GoldPulse())
    }
}

#Preview {
    Text("Premium")
        .foregroundColor(WRTheme.gold)
        .modifier(GoldPulse())
        .padding()
        .background(Color.black)
}
