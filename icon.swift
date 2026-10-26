import SwiftUI
let accent = Color(red: 0.42, green: 0.36, blue: 0.98), accent2 = Color(red: 0.18, green: 0.70, blue: 0.96)
struct IconView: View { var body: some View { ZStack {
  RoundedRectangle(cornerRadius: 230, style: .continuous).fill(LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.22), Color(red: 0.24, green: 0.16, blue: 0.46)], startPoint: .top, endPoint: .bottom)).frame(width: 824, height: 824)
  Circle().trim(from: 0.1, to: 0.9).stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 70, lineCap: .round)).rotationEffect(.degrees(90)).frame(width: 520, height: 520)
  Circle().trim(from: 0.1, to: 0.62).stroke(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 70, lineCap: .round)).rotationEffect(.degrees(90)).frame(width: 520, height: 520)
  Capsule().fill(Color.white).frame(width: 34, height: 220).offset(y: -95).rotationEffect(.degrees(40))
  Circle().fill(Color.white).frame(width: 90, height: 90)
}.frame(width: 1024, height: 1024) } }
@MainActor func run() { let r = ImageRenderer(content: IconView()); r.scale = 1
  if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) { try! png.write(to: URL(fileURLWithPath: "icon.png")) } }
MainActor.assumeIsolated { run() }
