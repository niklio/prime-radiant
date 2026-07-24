import Foundation

/// The strict JSON Schema sent with every model turn, derived from
/// `shared/schema/model-turn.schema.json` + `patch.schema.json` + `node.schema.json`
/// (bundled as resources; those files are the source of truth — keep this mirror
/// in sync, and add a schema-equivalence test once the strict transform is final).
///
/// Strict-mode transforms (OpenAI structured outputs): every property is required,
/// optionality is expressed as nullable types, `additionalProperties` is false
/// everywhere, and the optional `patch` becomes nullable (handoff §5.1).
///
/// TODO(M2): verify the current strict-schema constraints in OpenAI docs. Known
/// gap: strict mode has no open-keyed objects, so component payoffs
/// (`{component: value}`) can't be expressed — `payoff` is number|null here until
/// the encoding is settled (candidate: name/value pair array + client transform
/// before ModelTurnValidation).
enum ModelTurnSchema {

    /// The `text.format` schema payload for the Responses API request.
    static func strictSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["say", "patch"],
            "properties": [
                "say": [
                    "type": "string",
                    "description": "Plain prose for the human. Never describes JSON.",
                ],
                "patch": [
                    "type": ["array", "null"],
                    "items": ["$ref": "#/$defs/patchOp"],
                ],
            ],
            "$defs": [
                "node": nodeSchema(),
                "payoffUnit": payoffUnitSchema(),
                "patchOp": ["anyOf": patchOpVariants()],
            ],
        ]
    }

    private static func nodeSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "id", "label", "sub", "p", "actor", "move", "note",
                "payoff", "confidence", "children",
            ],
            "properties": [
                "id": ["type": "string"],
                "label": ["type": "string"],
                "sub": ["type": ["string", "null"]],
                "p": ["type": "number"],
                "actor": ["type": "string", "enum": ["user", "counterpart", "chance"]],
                "move": ["type": ["string", "null"]],
                "note": ["type": ["string", "null"]],
                "payoff": ["type": ["number", "null"]],
                "confidence": [
                    "type": ["string", "null"],
                    "enum": ["estimated", "user_set", "assumed", NSNull()],
                ],
                "children": [
                    "type": ["array", "null"],
                    "items": ["$ref": "#/$defs/node"],
                ],
            ],
        ]
    }

    private static func payoffUnitSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "label", "components"],
            "properties": [
                "kind": ["type": "string", "enum": ["currency", "utils", "scale"]],
                "label": ["type": "string"],
                "components": [
                    "type": ["array", "null"],
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["name", "weight"],
                        "properties": [
                            "name": ["type": "string"],
                            "weight": ["type": "number"],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func patchOpVariants() -> [[String: Any]] {
        func variant(_ op: String, _ properties: [String: Any]) -> [String: Any] {
            var merged: [String: Any] = ["op": ["type": "string", "enum": [op]]]
            merged.merge(properties) { current, _ in current }
            return [
                "type": "object",
                "additionalProperties": false,
                "required": Array(merged.keys).sorted(),
                "properties": merged,
            ]
        }
        return [
            variant("replace_tree", ["tree": ["$ref": "#/$defs/node"]]),
            variant(
                "upsert_node",
                [
                    "parentId": ["type": "string"],
                    "node": ["$ref": "#/$defs/node"],
                ]),
            variant(
                "update_node",
                [
                    "id": ["type": "string"],
                    "fields": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": [
                            "label", "sub", "p", "actor", "move", "note", "payoff",
                            "confidence",
                        ],
                        "properties": [
                            "label": ["type": ["string", "null"]],
                            "sub": ["type": ["string", "null"]],
                            "p": ["type": ["number", "null"]],
                            "actor": [
                                "type": ["string", "null"],
                                "enum": ["user", "counterpart", "chance", NSNull()],
                            ],
                            "move": ["type": ["string", "null"]],
                            "note": ["type": ["string", "null"]],
                            "payoff": ["type": ["number", "null"]],
                            "confidence": [
                                "type": ["string", "null"],
                                "enum": ["estimated", "user_set", "assumed", NSNull()],
                            ],
                        ],
                    ],
                ]),
            variant("remove_node", ["id": ["type": "string"]]),
            variant("mark_reached", ["id": ["type": "string"]]),
            variant("set_unit", ["payoffUnit": ["$ref": "#/$defs/payoffUnit"]]),
            variant("retitle_scenario", ["title": ["type": "string"]]),
        ]
    }
}
