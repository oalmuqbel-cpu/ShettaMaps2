import WidgetKit
import SwiftUI
import ActivityKit

@main
struct SamtWidgetsBundle: WidgetBundle {
    var body: some Widget { NavigationLiveActivity() }
}

struct NavigationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { ctx in
            LockScreenView(attributes: ctx.attributes, state: ctx.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Arrow(state: ctx.state).frame(width: 40, height: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(ActivityFormat.distance(ctx.state.remaining)).font(.title3.bold()).monospacedDigit()
                        if let eta = ctx.state.eta, !ctx.state.arrived {
                            Text(eta, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(ctx.state.arrived ? "وصلت إلى \(ctx.attributes.destination)"
                                           : "\(ctx.state.targetName) · \(ctx.state.cardinal)")
                        .font(.subheadline).lineLimit(1)
                }
            } compactLeading: {
                Arrow(state: ctx.state).frame(width: 20, height: 20)
            } compactTrailing: {
                Text(ActivityFormat.distance(ctx.state.remaining)).font(.caption.bold()).monospacedDigit()
            } minimal: {
                Arrow(state: ctx.state).frame(width: 18, height: 18)
            }
        }
    }
}

private struct Arrow: View {
    let state: NavigationActivityAttributes.ContentState
    var body: some View {
        if state.arrived {
            Image(systemName: "flag.checkered").resizable().scaledToFit().foregroundStyle(.green)
        } else {
            Image(systemName: "location.north.fill").resizable().scaledToFit()
                .rotationEffect(.degrees(state.arrowDegrees))
                .foregroundStyle(Color(red: 0.86, green: 0.55, blue: 0.27))
        }
    }
}

private struct LockScreenView: View {
    let attributes: NavigationActivityAttributes
    let state: NavigationActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            Arrow(state: state).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.destination).font(.headline).lineLimit(1)
                if state.arrived {
                    Text("وصلت").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(state.targetName == attributes.destination
                         ? "\(state.cardinal)" : "\(state.targetName) · \(ActivityFormat.distance(state.toTarget)) · \(state.cardinal)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ActivityFormat.distance(state.remaining)).font(.title2.bold()).monospacedDigit()
                if let eta = state.eta, !state.arrived {
                    Text(eta, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .environment(\.layoutDirection, .rightToLeft)
    }
}
