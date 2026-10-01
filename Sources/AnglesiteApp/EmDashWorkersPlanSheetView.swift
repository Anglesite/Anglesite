import SwiftUI
import AnglesiteCore

/// Asked once, the first time an EmDash site is published (#2116): whether the owner's Cloudflare
/// account is on the Workers Paid plan. The Website inspector's Workers Paid plan toggle changes
/// the answer later. The answer decides whether the site's Worker keeps cached
/// copies of its articles (`SiteSettings.emdashWorkersPaidPlan`). Worded about cost and speed,
/// never about caches or Workers configuration (decision D1). Mirrors `LicenseGateSheetView`'s
/// park-and-resume shape: answering saves the choice and publishes; Cancel publishes nothing and
/// asks again next time.
struct EmDashWorkersPlanSheetView: View {
    let model: DeployModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Is your Cloudflare account on the Workers Paid plan?")
                    .font(.headline)
                Text("On the Workers Paid plan, Anglesite keeps a ready copy of each article, so pages load faster and your site uses less of its computing time. Each change you publish replaces the copy right away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the free plan, keeping copies would use up the plan's daily limit of visits sooner, so Anglesite leaves it off. If you're not sure, choose Free Plan. You can change this later in the Website inspector.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.workersPlanQuestionError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Cancel") { model.cancelWorkersPlanQuestion() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Workers Paid") {
                    Task { await model.answerWorkersPlan(paid: true) }
                }
                .accessibilityIdentifier(AXID.deployWorkersPlanPaid)
                Button("Free Plan") {
                    Task { await model.answerWorkersPlan(paid: false) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AXID.deployWorkersPlanFree)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

#Preview {
    EmDashWorkersPlanSheetView(model: DeployModel())
}
