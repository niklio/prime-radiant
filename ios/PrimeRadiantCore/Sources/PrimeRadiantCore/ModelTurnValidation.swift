import Foundation

/// Decoding + validation of raw model output (handoff §5.1, §8): reject/retry malformed
/// turns with the validator error in-context — never let free text corrupt the tree.
public enum ModelTurnValidation {

    public enum TurnError: Error, Equatable {
        case notJSON(String)
        case schemaMismatch(String)
        case emptySay
        case invalidPatch(String)
    }

    /// Parse and validate a raw model turn. On success, the returned patch is
    /// guaranteed to apply cleanly to `scenario` (a dry run has already succeeded).
    public static func validate(rawJSON: Data, against scenario: Scenario) -> Result<ModelTurn, TurnError> {
        let decoder = JSONDecoder()
        let turn: ModelTurn
        do {
            turn = try decoder.decode(ModelTurn.self, from: rawJSON)
        } catch let error as DecodingError {
            return .failure(.schemaMismatch(describe(error)))
        } catch {
            return .failure(.notJSON(String(describing: error)))
        }
        guard !turn.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptySay)
        }
        if let patch = turn.patch, !patch.isEmpty {
            do {
                _ = try Patching.apply(patch, to: scenario, at: scenario.updatedAt)
            } catch {
                return .failure(.invalidPatch(String(describing: error)))
            }
        }
        return .success(turn)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(pathString(context))"
        case .typeMismatch(_, let context):
            return "type mismatch at \(pathString(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "null value at \(pathString(context))"
        case .dataCorrupted(let context):
            return "corrupt data at \(pathString(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func pathString(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "root" : path
    }
}
