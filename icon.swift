import SwiftUI
struct Hexagon: Shape { func path(in r: CGRect) -> Path { var p = Path(); let c = CGPoint(x: r.midX, y: r.midY); let rad = min(r.width, r.height)/2
  for i in 0..<6 { let a = CGFloat(i) * .pi/3 - .pi/2; let pt = CGPoint(x: c.x + rad*cos(a), y: c.y + rad*sin(a)); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }; p.closeSubpath(); return p } }
struct IconView: View { var body: some View { ZStack {
  RoundedRectangle(cornerRadius: 230).fill(LinearGradient(colors: [.white, Color(white: 0.93)], startPoint: .top, endPoint: .bottom)).frame(width: 824, height: 824)
  Hexagon().stroke(LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.35), Color(red: 1, green: 0.62, blue: 0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 90).frame(width: 600, height: 600)
  Image(systemName: "bolt.fill").font(.system(size: 220, weight: .bold)).foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.2), .orange], startPoint: .top, endPoint: .bottom))
}.frame(width: 1024, height: 1024) } }
@MainActor func run() { let r = ImageRenderer(content: IconView()); r.scale = 1
  if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) { try! png.write(to: URL(fileURLWithPath: "icon.png")) } }
MainActor.assumeIsolated { run() }
