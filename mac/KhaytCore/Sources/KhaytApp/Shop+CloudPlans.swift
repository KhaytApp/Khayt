import Foundation
import KhaytCore

/// Khayt Cloud's plans, for Settings › Online (`CloudPlanSettings`).
extension Shop {

    /// A seam, so a test can answer for the cloud.
    nonisolated(unsafe) static var plansFetch: S3.Fetch = { r in try await CloudReader.session.data(for: r) }

    /// What the plan card shows: the catalogue, and this shop's plan when it
    /// is signed in.
    struct CloudPlanState: Equatable {
        var catalogue: CloudPlans.Catalogue?
        var mine: CloudPlans.Mine?
        var problem: String?
    }

    /// Whether this sign-in is the shop's owner. Only the owner may change the
    /// plan (the cloud refuses anyone else with `owner-only`); a manager sees
    /// it and cannot change it. Unknown is NOT the owner here — the opposite
    /// of `cloudRoleCanWrite`, because the cost of a wrong yes is a button
    /// that answers "owner only", and the cloud still decides.
    var cloudIsOwner: Bool {
        guard case .object(let cloud)? = settingsDict["cloud"],
              case .string(let role)? = cloud["role"] else { return false }
        return role.lowercased() == "owner"
    }

    func cloudPlanState() async -> CloudPlanState {
        var state = CloudPlanState()
        guard let (connection, token) = await vaultSession() else {
            state.problem = words.callIt("mac.plan_sign_in")
            return state
        }
        do {
            state.catalogue = try await CloudPlans.catalogue(baseURL: connection.url, fetch: Self.plansFetch)
            state.mine = try await CloudPlans.mine(connection, token: token, fetch: Self.plansFetch)
        } catch {
            state.problem = planProblem(error)
        }
        return state
    }

    /// Move the shop to `plan`. Answers the new state, or the cloud's reason.
    /// Starts from what the pane already shows, so a refusal (or a reading
    /// that failed) never blanks the list or puts the shop on Free.
    func chooseCloudPlan(_ plan: String, from shown: CloudPlanState) async -> CloudPlanState {
        var state = shown
        guard let (connection, token) = await vaultSession() else { return state }
        do {
            state.mine = try await CloudPlans.choose(plan, connection, token: token, fetch: Self.plansFetch)
            state.problem = nil
        } catch {
            state.problem = planProblem(error)
        }
        return state
    }

    /// The cloud's refusal in the shop's language.
    func planProblem(_ error: Error) -> String {
        guard let r = error as? CloudPlans.Refusal else {
            return (error as? CustomStringConvertible)?.description ?? String(describing: error)
        }
        switch r.reason {
        case "owner-only": return words.callIt("mac.plan_owner_only")
        case "upgrades-closed": return words.callIt("mac.plan_opens_soon")
        case "beta-over": return words.callIt("mac.plan_beta_over")
        case "paid-plan": return words.callIt("mac.plan_paid")
        case "billing-off", "no-account": return words.callIt("mac.plan_unavailable")
        default: return r.description
        }
    }
}
