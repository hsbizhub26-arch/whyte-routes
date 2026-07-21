import SwiftUI
import WebKit

struct MapboxWebView: UIViewRepresentable {
    
    let htmlFile: String
    
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        
        if let url = Bundle.main.url(forResource: htmlFile, withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        
        return view
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
