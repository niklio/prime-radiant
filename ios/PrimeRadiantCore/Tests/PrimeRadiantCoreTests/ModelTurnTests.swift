import Foundation
import Testing
@testable import PrimeRadiantCore

@Suite struct ModelTurnTests {
    typealias J = Fixtures.JobOffer

    func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func decodesSayOnlyTurn() throws {
        let result = ModelTurnValidation.validate(
            rawJSON: data(#"{"say": "What are you optimizing for — cash, title, or optionality?"}"#),
            against: try Fixtures.jobOffer)
        let turn = try result.get()
        #expect(turn.patch == nil)
    }

    @Test func decodesFullPatchTurnAndRoundTrips() throws {
        let json = #"""
        {
          "say": "Rescission at −80 makes the counter marginal: EV drops to −1.45.",
          "patch": [
            {"op": "update_node", "id": "\#(J.rescind)", "fields": {"payoff": -80, "confidence": "user_set"}},
            {"op": "retitle_scenario", "title": "counter, riskier"}
          ]
        }
        """#
        let turn = try ModelTurnValidation.validate(rawJSON: data(json), against: try Fixtures.jobOffer).get()
        #expect(turn.patch?.count == 2)
        #expect(turn.patch?[0] == .updateNode(
            id: J.rescind, fields: NodeFields(payoff: .scalar(-80), confidence: .user_set)))

        // Round-trip: encode → decode is identity (the tree is the model's memory).
        let encoded = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(ModelTurn.self, from: encoded)
        #expect(decoded == turn)
    }

    @Test func rejectsFreeTextAndReportsPath() throws {
        let result = ModelTurnValidation.validate(
            rawJSON: data("Sure! Here's the updated tree: ..."), against: try Fixtures.jobOffer)
        guard case .failure(let error) = result else { Issue.record("accepted free text"); return }
        if case .schemaMismatch = error {} else if case .notJSON = error {} else {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func rejectsMissingSay() throws {
        let result = ModelTurnValidation.validate(
            rawJSON: data(#"{"patch": []}"#), against: try Fixtures.jobOffer)
        guard case .failure(.schemaMismatch(let message)) = result else {
            Issue.record("expected schemaMismatch"); return
        }
        #expect(message.contains("say"))
    }

    @Test func rejectsBlankSay() throws {
        let result = ModelTurnValidation.validate(
            rawJSON: data(#"{"say": "  \n"}"#), against: try Fixtures.jobOffer)
        #expect(result == .failure(.emptySay))
    }

    @Test func rejectsUnknownOp() throws {
        let result = ModelTurnValidation.validate(
            rawJSON: data(#"{"say": "ok", "patch": [{"op": "explode_tree"}]}"#),
            against: try Fixtures.jobOffer)
        guard case .failure(.schemaMismatch) = result else {
            Issue.record("expected schemaMismatch"); return
        }
    }

    @Test func dryRunCatchesSemanticallyInvalidPatch() throws {
        // Well-formed JSON, but the parent doesn't exist: validation must fail
        // before the turn ever reaches the real scenario.
        let json = #"""
        {"say": "ok", "patch": [
          {"op": "upsert_node", "parentId": "01J0PRABSENT00000000000000",
           "node": {"id": "01J0PRNEW00000000000000000", "label": "x", "p": 0.5, "actor": "chance"}}
        ]}
        """#
        let result = ModelTurnValidation.validate(rawJSON: data(json), against: try Fixtures.jobOffer)
        guard case .failure(.invalidPatch(let message)) = result else {
            Issue.record("expected invalidPatch"); return
        }
        #expect(message.contains("parentNotFound"))
    }

    @Test func validatorErrorMessagesAreRetryReady() throws {
        // The retry loop feeds the message back to the model — it must name the problem.
        let result = ModelTurnValidation.validate(
            rawJSON: data(#"{"say": "ok", "patch": [{"op": "update_node", "id": "x", "fields": {}}]}"#),
            against: try Fixtures.jobOffer)
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(String(describing: error).count > 10)
    }
}
