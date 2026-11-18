//! Request schemas, transcribed from the original Zod definitions. Older
//! protocol versions keep their own schemas so immutable mutations keep their
//! original parsing, defaults and receipt digests.

use crate::schema::*;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::LazyLock;

pub const PLACEMENTS: &[&str] = &["temporary", "spacePinned", "app"];
const OPS: &[&str] = &["upsert", "delete"];

fn entity_id() -> Schema {
    non_empty()
}

pub static AUTH_APPLE_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    object(vec![
        ("identityToken", non_empty()),
        ("deviceName", with_default(string_between(Some(1), Some(120)), json!("Mac"))),
        ("devicePlatform", with_default(string_between(Some(1), Some(60)), json!("macOS"))),
    ])
});

fn device_fields() -> Vec<(&'static str, Schema)> {
    vec![
        ("deviceName", with_default(string_between(Some(1), Some(120)), json!("Mac"))),
        ("devicePlatform", with_default(string_between(Some(1), Some(60)), json!("macOS"))),
    ]
}

pub static AUTH_WEB_EXCHANGE_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    let mut fields =
        vec![("code", string_between(Some(1), Some(200))), ("codeVerifier", string_between(Some(43), Some(128)))];
    fields.extend(device_fields());
    object(fields)
});

pub static AUTH_EMAIL_START_REQUEST: LazyLock<Schema> =
    LazyLock::new(|| object(vec![("email", string_between(Some(3), Some(254)))]));

pub static AUTH_EMAIL_VERIFY_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    let mut fields = vec![("email", string_between(Some(3), Some(254))), ("code", string_between(Some(6), Some(6)))];
    fields.extend(device_fields());
    object(fields)
});

pub static REGISTER_DEVICE_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    object(vec![
        ("name", string_between(Some(1), Some(120))),
        ("platform", string_between(Some(1), Some(60))),
        ("publicKey", optional(string_between(None, Some(4096)))),
    ])
});

// MARK: Space and tab payloads

fn space_fields(include_rank: bool) -> Vec<(&'static str, Schema)> {
    let mut fields = vec![("title", non_empty()), ("systemImageName", non_empty())];
    if include_rank {
        fields.push(("rank", number()));
    }
    fields.push(("isPinnedSectionCollapsed", with_default(Schema::Boolean, json!(false))));
    fields.push(("selectedTabID", optional(nullable(string()))));
    fields
}

fn tab_fields(include_rank: bool) -> Vec<(&'static str, Schema)> {
    let mut fields = vec![("spaceID", non_empty()), ("placement", options(PLACEMENTS))];
    if include_rank {
        fields.push(("rank", number()));
    }
    fields.extend([
        ("urlString", non_empty()),
        ("pinnedURLString", optional(nullable(non_empty()))),
        ("title", optional(nullable(string()))),
        ("userTitleOverride", optional(nullable(string()))),
        ("faviconURLString", optional(nullable(string()))),
        ("lastActivityAt", optional(nullable(date_time()))),
    ]);
    fields
}

fn upsert_requires_data(value: &Value, issues: &mut Vec<Issue>) {
    if value.get("op") == Some(&json!("upsert")) && value.get("data").is_none() {
        issues.push(Issue::custom(&["data"], "Upsert requires entity data"));
    }
}

fn sync_change() -> Schema {
    refined(
        Schema::Discriminated {
            key: "entityType",
            options: vec![
                object(vec![
                    ("entityType", literal(json!("space"))),
                    ("entityID", non_empty()),
                    ("op", options(OPS)),
                    ("data", optional(object(space_fields(true)))),
                ]),
                object(vec![
                    ("entityType", literal(json!("tab"))),
                    ("entityID", non_empty()),
                    ("op", options(OPS)),
                    ("data", optional(object(tab_fields(true)))),
                ]),
            ],
        },
        upsert_requires_data,
    )
}

fn legacy_push_request() -> Schema {
    refined(
        object(vec![
            ("deviceID", uuid()),
            ("changes", array(sync_change(), None, Some(1000))),
            ("protocolVersion", optional(literal(json!(2)))),
            ("mutationID", optional(uuid())),
        ]),
        |value, issues| {
            if value.get("protocolVersion").is_none() != value.get("mutationID").is_none() {
                issues.push(Issue::custom(&[], "protocolVersion 2 and mutationID must be supplied together"));
            }
        },
    )
}

// MARK: Version 3 operations

fn anchors() -> Vec<(&'static str, Schema)> {
    vec![("beforeID", optional(nullable(entity_id()))), ("afterID", optional(nullable(entity_id())))]
}

fn space_create_data() -> Schema {
    strict(space_fields(false))
}

fn tab_create_data() -> Schema {
    strict(tab_fields(false))
}

fn requires_fields(value: &Value, issues: &mut Vec<Issue>) {
    if value.as_object().is_some_and(|fields| fields.is_empty()) {
        issues.push(Issue::custom(&[], "Patch requires fields"));
    }
}

fn space_patch_fields() -> Schema {
    refined(
        strict(vec![
            ("title", optional(non_empty())),
            ("systemImageName", optional(non_empty())),
            ("selectedTabID", optional(nullable(string()))),
            ("isPinnedSectionCollapsed", optional(Schema::Boolean)),
        ]),
        requires_fields,
    )
}

fn tab_patch_fields() -> Schema {
    refined(
        strict(vec![
            ("urlString", optional(non_empty())),
            ("pinnedURLString", optional(nullable(non_empty()))),
            ("title", optional(nullable(string()))),
            ("userTitleOverride", optional(nullable(string()))),
            ("faviconURLString", optional(nullable(string()))),
            ("lastActivityAt", optional(nullable(date_time()))),
        ]),
        requires_fields,
    )
}

fn move_ids() -> Schema {
    refined(array(entity_id(), Some(1), Some(1000)), |value, issues| {
        let ids = value.as_array().into_iter().flatten().filter_map(Value::as_str).collect::<Vec<_>>();
        if ids.iter().collect::<HashSet<_>>().len() != ids.len() {
            issues.push(Issue::custom(&[], "Move IDs must be unique"));
        }
    })
}

fn with(mut fields: Vec<(&'static str, Schema)>, extra: Vec<(&'static str, Schema)>) -> Vec<(&'static str, Schema)> {
    fields.extend(extra);
    fields
}

fn sync_operation_v3() -> Schema {
    refined(
        Schema::Union(vec![
            strict(with(
                vec![
                    ("kind", literal(json!("create"))),
                    ("entityType", literal(json!("space"))),
                    ("entityID", entity_id()),
                    ("data", space_create_data()),
                ],
                anchors(),
            )),
            strict(with(
                vec![
                    ("kind", literal(json!("create"))),
                    ("entityType", literal(json!("tab"))),
                    ("entityID", entity_id()),
                    ("data", tab_create_data()),
                ],
                anchors(),
            )),
            strict(vec![
                ("kind", literal(json!("patch"))),
                ("entityType", literal(json!("space"))),
                ("entityID", entity_id()),
                ("fields", space_patch_fields()),
            ]),
            strict(vec![
                ("kind", literal(json!("patch"))),
                ("entityType", literal(json!("tab"))),
                ("entityID", entity_id()),
                ("fields", tab_patch_fields()),
            ]),
            strict(with(
                vec![
                    ("kind", literal(json!("move"))),
                    ("entityType", literal(json!("space"))),
                    ("entityIDs", move_ids()),
                ],
                anchors(),
            )),
            strict(with(
                vec![
                    ("kind", literal(json!("move"))),
                    ("entityType", literal(json!("tab"))),
                    ("entityIDs", move_ids()),
                    ("destination", strict(vec![("spaceID", entity_id()), ("placement", options(PLACEMENTS))])),
                ],
                anchors(),
            )),
            strict(vec![
                ("kind", literal(json!("delete"))),
                ("entityType", options(&["space", "tab"])),
                ("entityID", entity_id()),
            ]),
        ]),
        |value, issues| {
            if value.get("kind") != Some(&json!("move")) {
                return;
            }
            let ids = value.get("entityIDs").and_then(Value::as_array).cloned().unwrap_or_default();
            let anchored = ["beforeID", "afterID"]
                .iter()
                .filter_map(|key| value.get(*key))
                .any(|anchor| !anchor.is_null() && ids.contains(anchor));
            if anchored {
                issues.push(Issue::custom(&[], "Move anchors cannot belong to the moving group"));
            }
        },
    )
}

fn semantic_push_request() -> Schema {
    strict(vec![
        ("deviceID", uuid()),
        ("protocolVersion", literal(json!(3))),
        ("mutationID", uuid()),
        ("operations", array(sync_operation_v3(), None, Some(1000))),
    ])
}

// MARK: Version 4 folders and typed references

fn validate_tab_folder(value: &Value, issues: &mut Vec<Issue>) {
    let placement = value.get("placement").and_then(Value::as_str);
    let folder = value.get("pinnedFolderID");
    if placement != Some("spacePinned") && folder.is_some_and(|folder| !folder.is_null()) {
        issues.push(Issue::custom(&["pinnedFolderID"], "Only pinned tabs can belong to a folder"));
    }
}

fn tab_fields_v4(include_rank: bool) -> Vec<(&'static str, Schema)> {
    with(tab_fields(include_rank), vec![("pinnedFolderID", nullable(entity_id()))])
}

fn folder_fields(include_rank: bool) -> Vec<(&'static str, Schema)> {
    let mut fields = vec![
        ("spaceID", entity_id()),
        ("parentFolderID", nullable(entity_id())),
        ("title", non_empty()),
        ("systemImageName", optional(nullable(non_empty()))),
    ];
    if include_rank {
        fields.push(("rank", number()));
    }
    fields
}

fn folder_patch_fields() -> Schema {
    refined(
        strict(vec![("title", optional(non_empty())), ("systemImageName", optional(nullable(non_empty())))]),
        requires_fields,
    )
}

fn entity_reference() -> Schema {
    strict(vec![("entityType", options(&["space", "tab", "folder"])), ("entityID", entity_id())])
}

fn reference_key(value: &Value) -> String {
    format!(
        "{}:{}",
        value.get("entityType").and_then(Value::as_str).unwrap_or_default(),
        value.get("entityID").and_then(Value::as_str).unwrap_or_default()
    )
}

fn typed_anchors() -> Vec<(&'static str, Schema)> {
    vec![("before", optional(nullable(entity_reference()))), ("after", optional(nullable(entity_reference())))]
}

fn move_items_v4() -> Schema {
    refined(array(entity_reference(), Some(1), Some(1000)), |value, issues| {
        let keys = value.as_array().into_iter().flatten().map(reference_key).collect::<Vec<_>>();
        if keys.iter().collect::<HashSet<_>>().len() != keys.len() {
            issues.push(Issue::custom(&[], "Move items must be unique"));
        }
    })
}

fn destination_v4() -> Schema {
    refined(
        Schema::Discriminated {
            key: "kind",
            options: vec![
                strict(vec![("kind", literal(json!("spaces")))]),
                strict(vec![
                    ("kind", literal(json!("tabs"))),
                    ("spaceID", entity_id()),
                    ("placement", options(PLACEMENTS)),
                    ("pinnedFolderID", nullable(entity_id())),
                ]),
            ],
        },
        |value, issues| {
            if value.get("kind") == Some(&json!("tabs")) {
                validate_tab_folder(value, issues);
            }
        },
    )
}

fn sync_operation_v4() -> Schema {
    refined(
        Schema::Union(vec![
            strict(with(
                vec![
                    ("kind", literal(json!("create"))),
                    ("entityType", literal(json!("space"))),
                    ("entityID", entity_id()),
                    ("data", space_create_data()),
                ],
                typed_anchors(),
            )),
            strict(with(
                vec![
                    ("kind", literal(json!("create"))),
                    ("entityType", literal(json!("tab"))),
                    ("entityID", entity_id()),
                    ("data", refined(strict(tab_fields_v4(false)), validate_tab_folder)),
                ],
                typed_anchors(),
            )),
            strict(with(
                vec![
                    ("kind", literal(json!("create"))),
                    ("entityType", literal(json!("folder"))),
                    ("entityID", entity_id()),
                    ("data", strict(folder_fields(false))),
                ],
                typed_anchors(),
            )),
            strict(vec![
                ("kind", literal(json!("patch"))),
                ("entityType", literal(json!("space"))),
                ("entityID", entity_id()),
                ("fields", space_patch_fields()),
            ]),
            strict(vec![
                ("kind", literal(json!("patch"))),
                ("entityType", literal(json!("tab"))),
                ("entityID", entity_id()),
                ("fields", tab_patch_fields()),
            ]),
            strict(vec![
                ("kind", literal(json!("patch"))),
                ("entityType", literal(json!("folder"))),
                ("entityID", entity_id()),
                ("fields", folder_patch_fields()),
            ]),
            strict(with(
                vec![("kind", literal(json!("move"))), ("items", move_items_v4()), ("destination", destination_v4())],
                typed_anchors(),
            )),
            strict(vec![
                ("kind", literal(json!("delete"))),
                ("entityType", options(&["space", "tab", "folder"])),
                ("entityID", entity_id()),
            ]),
        ]),
        |value, issues| {
            if value.get("kind") != Some(&json!("move")) {
                return;
            }
            let items = value.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            let keys = items.iter().map(reference_key).collect::<HashSet<_>>();
            let anchored = ["before", "after"]
                .iter()
                .filter_map(|key| value.get(*key))
                .any(|anchor| !anchor.is_null() && keys.contains(&reference_key(anchor)));
            if anchored {
                issues.push(Issue::custom(&[], "Move anchors cannot belong to the moving group"));
            }
            let destination = value.get("destination").cloned().unwrap_or(Value::Null);
            let entity_type =
                |item: &Value| item.get("entityType").and_then(Value::as_str).unwrap_or_default().to_string();
            if destination.get("kind") == Some(&json!("spaces")) {
                if items.iter().any(|item| entity_type(item) != "space") {
                    issues.push(Issue::custom(&["items"], "Only spaces belong to the spaces list"));
                }
            } else if items.iter().any(|item| {
                entity_type(item) == "space"
                    || (entity_type(item) == "folder" && destination.get("placement") != Some(&json!("spacePinned")))
            }) {
                issues.push(Issue::custom(
                    &["items"],
                    "Folders require a pinned destination; spaces cannot move into tab lists",
                ));
            }
        },
    )
}

fn push_request_v4() -> Schema {
    strict(vec![
        ("deviceID", uuid()),
        ("protocolVersion", literal(json!(4))),
        ("mutationID", uuid()),
        ("operations", array(sync_operation_v4(), None, Some(1000))),
    ])
}

// MARK: Version 5 conditional expiry

pub const EXPIRY_INTERVALS: [u64; 5] = [43_200, 86_400, 259_200, 604_800, 2_592_000];

fn expiry_operation() -> Schema {
    strict(vec![
        ("kind", literal(json!("expire"))),
        ("entityType", literal(json!("tab"))),
        ("entityID", entity_id()),
        ("expectedServerSeq", integer(Some((0.0, false)), Some((MAX_SAFE_INTEGER, true)))),
        ("inactiveForSeconds", Schema::Union(EXPIRY_INTERVALS.iter().map(|seconds| literal(json!(seconds))).collect())),
    ])
}

fn push_request_v5() -> Schema {
    strict(vec![
        ("deviceID", uuid()),
        ("protocolVersion", literal(json!(5))),
        ("mutationID", uuid()),
        ("operations", array(expiry_operation(), None, Some(100))),
    ])
}

// MARK: Version 6 boosts

/// Limits in UTF-16 code units, as the other string fields count them.
pub const BOOST_HOST_LIMIT: usize = 253;
pub const BOOST_CODE_LIMIT: usize = 262_144;
pub const BOOST_SELECTOR_LIMIT: usize = 4096;
pub const BOOST_SELECTOR_COUNT_LIMIT: usize = 1000;
pub const BOOST_TITLE_LIMIT: usize = 1024;
pub const BOOST_FONT_FAMILY_LIMIT: usize = 256;
const BOOST_TEXT_CASES: &[&str] = &["capitalize", "uppercase", "lowercase"];

fn number_within(min: f64, max: f64) -> Schema {
    Schema::Number { int: false, min: Some((min, true)), max: Some((max, true)) }
}

/// A tint on the color wheel and the color sliders. Ranges are wider than the
/// editor's, so a later editor can widen its own without a new protocol.
fn boost_colors() -> Schema {
    strict(vec![
        (
            "tint",
            optional(strict(vec![
                ("hue", number_within(0.0, 360.0)),
                ("saturation", number_within(0.0, 1.0)),
                ("secondaryHueOffset", number_within(-360.0, 360.0)),
            ])),
        ),
        ("invertsLightness", Schema::Boolean),
        ("contrast", number_within(0.0, 4.0)),
        ("brightness", number_within(0.0, 4.0)),
        ("originalSaturation", number_within(0.0, 1.0)),
    ])
}

/// What the editor's controls change; an absent field keeps the site's own.
fn boost_style() -> Schema {
    strict(vec![
        ("colors", optional(boost_colors())),
        ("fontFamily", optional(string_between(Some(1), Some(BOOST_FONT_FAMILY_LIMIT)))),
        ("textCase", optional(options(BOOST_TEXT_CASES))),
        ("textZoom", optional(number_within(0.25, 4.0))),
    ])
}

fn boost_data() -> Schema {
    strict(vec![
        ("host", string_between(Some(1), Some(BOOST_HOST_LIMIT))),
        ("isEnabled", Schema::Boolean),
        ("css", string_between(None, Some(BOOST_CODE_LIMIT))),
        ("javaScript", string_between(None, Some(BOOST_CODE_LIMIT))),
        (
            "zappedSelectors",
            array(string_between(Some(1), Some(BOOST_SELECTOR_LIMIT)), None, Some(BOOST_SELECTOR_COUNT_LIMIT)),
        ),
        ("title", optional(string_between(Some(1), Some(BOOST_TITLE_LIMIT)))),
        ("style", optional(boost_style())),
    ])
}

/// A whole boost replaces the stored one; a delete is permanent.
fn boost_operation() -> Schema {
    Schema::Discriminated {
        key: "kind",
        options: vec![
            strict(vec![
                ("kind", literal(json!("upsert"))),
                ("entityType", literal(json!("boost"))),
                ("entityID", string_between(Some(1), Some(200))),
                ("data", boost_data()),
            ]),
            strict(vec![
                ("kind", literal(json!("delete"))),
                ("entityType", literal(json!("boost"))),
                ("entityID", string_between(Some(1), Some(200))),
            ]),
        ],
    }
}

fn push_request_v6() -> Schema {
    strict(vec![
        ("deviceID", uuid()),
        ("protocolVersion", literal(json!(6))),
        ("mutationID", uuid()),
        ("operations", array(boost_operation(), None, Some(1000))),
    ])
}

pub static SYNC_PUSH_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    Schema::Union(vec![
        push_request_v6(),
        push_request_v5(),
        push_request_v4(),
        semantic_push_request(),
        legacy_push_request(),
    ])
});

// MARK: Pull

fn pull_fields() -> Vec<(&'static str, Schema)> {
    vec![
        ("deviceID", uuid()),
        ("cursor", with_default(integer(Some((0.0, true)), None), json!(0))),
        ("limit", with_default(integer(Some((0.0, false)), Some((1000.0, true))), json!(500))),
    ]
}

/// A malformed explicit versioned request must not fall back to the legacy
/// parser, which strips unknown fields for existing clients.
pub static SYNC_PULL_REQUEST: LazyLock<Schema> = LazyLock::new(|| {
    Schema::Union(vec![
        strict(with(pull_fields(), vec![("protocolVersion", literal(json!(6)))])),
        strict(with(pull_fields(), vec![("protocolVersion", literal(json!(5)))])),
        strict(with(pull_fields(), vec![("protocolVersion", literal(json!(4)))])),
        object(with(pull_fields(), vec![("protocolVersion", optional(Schema::Undefined))])),
    ])
});

// MARK: Shares

const SHARE_ITEM_TYPES: &[&str] = &["tab", "folder"];

fn share_item() -> Schema {
    object(vec![
        ("type", options(SHARE_ITEM_TYPES)),
        ("title", optional(nullable(string_between(None, Some(300))))),
        ("url", optional(nullable(string_between(Some(1), Some(4096))))),
        ("favicon", optional(nullable(string_between(Some(1), Some(16_416))))),
        ("icon", optional(nullable(string_between(Some(1), Some(64))))),
        ("parent", optional(nullable(integer(Some((0.0, true)), Some((1000.0, false)))))),
    ])
}

fn share_collection(kind: &'static str) -> Schema {
    object(vec![
        ("kind", literal(json!(kind))),
        ("sourceID", string_between(Some(1), Some(200))),
        ("title", string_between(Some(1), Some(200))),
        ("icon", optional(nullable(string_between(Some(1), Some(64))))),
        ("iconImage", optional(nullable(string_between(Some(1), Some(16_416))))),
        ("colors", with_default(array(string_between(Some(7), Some(7)), None, Some(8)), json!([]))),
        ("items", array(share_item(), Some(1), Some(1000))),
    ])
}

pub static SHARE_PUBLISH_REQUEST: LazyLock<Schema> = LazyLock::new(|| Schema::Discriminated {
    key: "kind",
    options: vec![
        share_collection("space"),
        share_collection("folder"),
        object(vec![
            ("kind", literal(json!("quote"))),
            ("text", string_between(Some(1), Some(2000))),
            ("title", optional(nullable(string_between(None, Some(300))))),
            ("url", string_between(Some(1), Some(8192))),
            ("favicon", optional(nullable(string_between(Some(1), Some(16_416))))),
        ]),
    ],
});

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_json;

    #[derive(serde::Deserialize)]
    struct DigestCase {
        body: String,
        canonical: String,
        digest: String,
    }

    /// Receipt digests computed by the original JavaScript server for the same
    /// bodies (`tests/fixtures/push-digests.json`).
    #[test]
    fn push_digests_match_the_original_server() {
        let cases: Vec<DigestCase> =
            serde_json::from_str(include_str!("../tests/fixtures/push-digests.json")).expect("fixture");
        assert!(!cases.is_empty());
        for case in cases {
            let body: Value = serde_json::from_str(&case.body).unwrap();
            let parsed = SYNC_PUSH_REQUEST.parse(&body).unwrap_or_else(|issues| panic!("{}", format_issues(&issues)));
            let payload = crate::sync::receipt_payload(&parsed);
            assert_eq!(js_json::stringify(&js_json::canonical(&payload)), case.canonical);
            assert_eq!(js_json::digest(&payload), case.digest);
        }
    }

    #[test]
    fn pull_requests_report_field_issues_and_reject_unknown_versioned_fields() {
        let issues =
            SYNC_PULL_REQUEST.parse(&json!({"deviceID": "not-a-uuid", "cursor": -1, "limit": 1001})).unwrap_err();
        let message = format_issues(&issues);
        assert!(message.contains("deviceID") && message.contains("cursor") && message.contains("limit"), "{message}");
        let device = "00000000-0000-4000-8000-000000000001";
        assert!(SYNC_PULL_REQUEST.parse(&json!({"deviceID": device, "protocolVersion": 4, "extra": 1})).is_err());
        assert_eq!(
            SYNC_PULL_REQUEST.parse(&json!({"deviceID": device, "extra": 1})).unwrap(),
            json!({"deviceID": device, "cursor": 0.0, "limit": 500.0})
        );
        assert!(SYNC_PULL_REQUEST.parse(&json!({"deviceID": device, "cursor": 1.5})).is_err());
    }

    #[test]
    fn push_requests_validate_versions_envelopes_and_operations() {
        let device = "00000000-0000-4000-8000-000000000001";
        let mutation = "00000000-0000-4000-8000-000000000002";
        assert!(SYNC_PUSH_REQUEST.parse(&json!({"deviceID": device, "changes": []})).is_ok());
        // Version 2 needs a mutation ID, and a mutation ID needs version 2.
        assert!(SYNC_PUSH_REQUEST.parse(&json!({"deviceID": device, "protocolVersion": 2, "changes": []})).is_err());
        assert!(SYNC_PUSH_REQUEST.parse(&json!({"deviceID": device, "mutationID": mutation, "changes": []})).is_err());
        // Structural fields cannot be patched.
        let patch = json!({"kind": "patch", "entityType": "tab", "entityID": "t", "fields": {"spaceID": "s"}});
        assert!(
            SYNC_PUSH_REQUEST
                .parse(
                    &json!({"deviceID": device, "protocolVersion": 3, "mutationID": mutation, "operations": [patch]})
                )
                .is_err()
        );
        // A move anchor cannot be one of the moving items.
        let anchored = json!({"kind": "move", "entityType": "space", "entityIDs": ["a"], "beforeID": "a"});
        assert!(
            SYNC_PUSH_REQUEST
                .parse(
                    &json!({"deviceID": device, "protocolVersion": 3, "mutationID": mutation, "operations": [anchored]})
                )
                .is_err()
        );
        // Folders need a pinned destination.
        let folder_move = json!({"kind": "move", "items": [{"entityType": "folder", "entityID": "f"}],
            "destination": {"kind": "tabs", "spaceID": "s", "placement": "temporary", "pinnedFolderID": null}});
        assert!(SYNC_PUSH_REQUEST
            .parse(&json!({"deviceID": device, "protocolVersion": 4, "mutationID": mutation, "operations": [folder_move]}))
            .is_err());
        // Boosts carry a whole record and nothing else.
        let boost = json!({"kind": "upsert", "entityType": "boost", "entityID": "b", "data": {
            "host": "example.com", "isEnabled": true, "css": "", "javaScript": "", "zappedSelectors": ["#ad"]}});
        let boost_push = |operation: &Value| {
            SYNC_PUSH_REQUEST.parse(
                &json!({"deviceID": device, "protocolVersion": 6, "mutationID": mutation, "operations": [operation]}),
            )
        };
        assert!(boost_push(&boost).is_ok());
        assert!(boost_push(&json!({"kind": "delete", "entityType": "boost", "entityID": "b"})).is_ok());
        let mut extra = boost.clone();
        extra["data"]["subtitle"] = json!("x");
        assert!(boost_push(&extra).is_err());
        // The name and the editor's styling travel with the boost, within bounds.
        let mut styled = boost.clone();
        styled["data"]["title"] = json!("Reader");
        styled["data"]["style"] = json!({
            "colors": {"tint": {"hue": 210.5, "saturation": 0.4, "secondaryHueOffset": 30},
                       "invertsLightness": true, "contrast": 1.2, "brightness": 0.9, "originalSaturation": 0},
            "fontFamily": "Georgia", "textCase": "uppercase", "textZoom": 1.25});
        assert!(boost_push(&styled).is_ok());
        let mut plain_style = boost.clone();
        plain_style["data"]["style"] = json!({});
        assert!(boost_push(&plain_style).is_ok());
        for (path, value) in [
            ("/data/title", json!("")),
            ("/data/title", json!("a".repeat(BOOST_TITLE_LIMIT + 1))),
            ("/data/title", json!(null)),
            ("/data/style", json!("dark")),
            ("/data/style/fontFamily", json!("")),
            ("/data/style/textCase", json!("smallcaps")),
            ("/data/style/textZoom", json!(9)),
            ("/data/style/colors/contrast", json!(-1)),
            ("/data/style/colors/tint/hue", json!(400)),
            ("/data/style/colors/shadow", json!(1)),
            ("/data/style/glow", json!(true)),
        ] {
            let mut invalid = styled.clone();
            let (parent, key) = path.rsplit_once('/').unwrap();
            invalid.pointer_mut(parent).unwrap().as_object_mut().unwrap().insert(key.to_string(), value.clone());
            assert!(boost_push(&invalid).is_err(), "{path} = {value}");
        }
        let mut missing = styled.clone();
        missing["data"]["style"]["colors"].as_object_mut().unwrap().remove("contrast");
        assert!(boost_push(&missing).is_err());
        let mut empty_host = boost.clone();
        empty_host["data"]["host"] = json!("");
        assert!(boost_push(&empty_host).is_err());
        let mut huge = boost.clone();
        huge["data"]["css"] = json!("a".repeat(BOOST_CODE_LIMIT + 1));
        assert!(boost_push(&huge).is_err());
        assert!(boost_push(&json!({"kind": "patch", "entityType": "boost", "entityID": "b", "fields": {}})).is_err());
        assert!(boost_push(&json!({"kind": "delete", "entityType": "tab", "entityID": "b"})).is_err());
        assert!(SYNC_PULL_REQUEST.parse(&json!({"deviceID": device, "protocolVersion": 6})).is_ok());
        // Expiry takes only the five intervals.
        let expiry = json!({"kind": "expire", "entityType": "tab", "entityID": "t", "expectedServerSeq": 1, "inactiveForSeconds": 60});
        assert!(
            SYNC_PUSH_REQUEST
                .parse(
                    &json!({"deviceID": device, "protocolVersion": 5, "mutationID": mutation, "operations": [expiry]})
                )
                .is_err()
        );
    }
}
