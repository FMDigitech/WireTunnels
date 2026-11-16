import Foundation

@main
struct LinkQualityTests {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 0)
        func samples(_ values: [Double?]) -> [ProbeSample] {
            values.enumerated().map { ProbeSample(time: t0.addingTimeInterval(Double($0.offset)), latencyMs: $0.element) }
        }
        let thresholds = QualityThresholds.standard

        let calm = LinkQualityStats(samples: samples([20, 22, 25, 30, 41]))
        precondition(calm.medianMs == 25 && calm.p95Ms == 41 && calm.lost == 0, "median and 95% come from sorted replies")
        precondition(thresholds.level(for: calm) == .good, "low latency, no loss is good")

        let slow = LinkQualityStats(samples: samples([70, 80, 90]))
        precondition(thresholds.level(for: slow) == .fair, "60 ms or more is fair")
        precondition(thresholds.level(for: LinkQualityStats(samples: samples([200, 210]))) == .poor, "150 ms or more is poor")

        let lossy = LinkQualityStats(samples: samples([20, nil, 20, 20, 20]))
        precondition(lossy.lossPercent == 20, "1 of 5 lost is 20%")
        precondition(thresholds.level(for: lossy) == .poor, "loss over 3% is poor")

        let allLost = LinkQualityStats(samples: samples([nil, nil]))
        precondition(thresholds.level(for: allLost) == .poor, "no reply at all is poor, not unmeasured")
        precondition(thresholds.level(for: LinkQualityStats(samples: [])) == .unmeasured, "no probes means not measured")

        precondition(QualityThresholds(fairPingMs: 100, poorPingMs: 50).isValid == false, "fair above poor is invalid")
        let plan = ProbePlan(intervalSeconds: 5, retentionHours: 24)
        precondition(plan.probesPerDay == 17_280, "one probe every 5 s is 17,280 a day")
        precondition(RateFormat.text(mbps: 92.46) == "92.5 Mbps" && RateFormat.text(mbps: 250) == "250 Mbps", "busy rates read in Mbps")
        precondition(RateFormat.text(mbps: 0.024) == "24.0 kbps", "3 KB/s must not read 0.0 Mbps")
        precondition(RateFormat.text(mbps: 0.35) == "350 kbps" && RateFormat.text(mbps: 0.0004) == "<1 kbps", "quiet rates read in kbps")
        precondition(RateFormat.text(mbps: 0) == "0 kbps", "only an exact zero reads zero")
        print("PASS: link quality verdicts, percentiles, thresholds, probe cost and rate formatting")
    }
}
