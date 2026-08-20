import SwiftUI
import Charts

private struct Plotted: Identifiable {
    let id: String
    let t: Double
    let value: Double
    let direction: String
}

/// The rolling read/write graph.
///
/// Y is rescaled to the window's own peak so a 40 MB/s stick and a 1 GB/s
/// enclosure are both legible — with the axis labelled, because an unlabelled
/// auto-scaling graph tells you nothing about magnitude.
struct ThroughputChart: View, Equatable {
    var points: [GraphPoint]
    var ceilingMBps: Double?
    var height: CGFloat = 170

    private var plotted: [Plotted] {
        points.flatMap { p in
            [Plotted(id: "r\(p.id)", t: p.t, value: p.read, direction: "Read"),
             Plotted(id: "w\(p.id)", t: p.t, value: p.write, direction: "Write")]
        }
    }

    private var yMax: Double {
        let peak = points.reduce(0.0) { max($0, max($1.read, $1.write)) }
        guard peak > 0 else { return 10 }
        // Snap to a human number so the axis does not jitter on every tick.
        let steps: [Double] = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2000, 5000]
        return steps.first { $0 >= peak * 1.15 } ?? peak * 1.15
    }

    var body: some View {
        Chart {
            ForEach(plotted) { p in
                AreaMark(x: .value("Time", p.t), y: .value("MB/s", p.value))
                    .foregroundStyle(by: .value("Direction", p.direction))
                    .opacity(0.15)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.t), y: .value("MB/s", p.value))
                    .foregroundStyle(by: .value("Direction", p.direction))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let ceiling = ceilingMBps, ceiling <= yMax {
                RuleMark(y: .value("Link ceiling", ceiling))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.tertiary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("link ceiling")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .chartForegroundStyleScale(["Read": Ink.read, "Write": Ink.write])
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Format.axisTick(v))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 8)
        .frame(height: height)
    }
}

/// A 40×14 trace for a sidebar row.
///
/// Deliberately a `Path` and not a `Chart`: this draws once per row per publish
/// tick, and a Charts instance per row would undo the work that keeps the app
/// under 1% at idle.
struct Sparkline: View, Equatable {
    var points: [GraphPoint]
    var tint: Color
    var fixedSize: CGSize? = CGSize(width: 42, height: 14)

    var body: some View {
        Canvas { context, size in
            let values = points.suffix(40).map { $0.read + $0.write }
            guard values.count > 1, let peak = values.max(), peak > 0 else { return }

            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * Double(i) / Double(values.count - 1)
                let y = size.height * (1 - v / peak)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: fixedSize?.width, height: fixedSize?.height)
    }
}

/// Live MB/s trace for a benchmark phase — this is what makes a cache cliff or
/// a stall sawtooth visible as a shape rather than an averaged-away number.
struct BenchmarkCurveChart: View {
    var curve: [(Double, Double)]
    var tint: Color
    var height: CGFloat = 120

    private struct Point: Identifiable {
        let id: Int
        let t: Double
        let v: Double
    }

    private var data: [Point] {
        curve.enumerated().map { Point(id: $0.offset, t: $0.element.0, v: $0.element.1) }
    }

    var body: some View {
        Chart(data) { p in
            AreaMark(x: .value("Seconds", p.t), y: .value("MB/s", p.v))
                .foregroundStyle(tint.opacity(0.15))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Seconds", p.t), y: .value("MB/s", p.v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))s").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Format.axisTick(v))
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: height)
    }
}
