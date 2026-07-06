import Foundation

struct TrafficSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rxRate: Double  // bytes/sec
    let txRate: Double  // bytes/sec
}
