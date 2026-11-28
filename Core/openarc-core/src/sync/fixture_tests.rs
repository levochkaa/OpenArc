//! The projections against what the Swift code they replaced answered, for random sessions, edits,
//! queues and server events. `tests/fixtures/sync-projections.json.gz` holds the inputs in the wire
//! format and the Swift answers; `OPENARC_SYNC_FIXTURES` can name more such files, comma-separated.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Read;

use serde_json::Value;

use super::dates;
use super::folders;
use super::model::*;
use super::outbox::{
    self, Baseline, CoreSyncBaselineEntity, CoreSyncEvent, CoreSyncEventData, CoreSyncEventFolderData,
};
use super::outbox::{CoreSyncEventSpaceData, CoreSyncEventTabData};
use super::semantic;

const CHECKED_IN: &[u8] = include_bytes!("../../tests/fixtures/sync-projections.json.gz");

fn fixtures() -> Vec<Value> {
    let mut sources = vec![CHECKED_IN.to_vec()];
    if let Ok(paths) = std::env::var("OPENARC_SYNC_FIXTURES") {
        for path in paths.split(',').filter(|path| !path.is_empty()) {
            sources.push(std::fs::read(path).unwrap_or_else(|error| panic!("{path}: {error}")));
        }
    }
    sources
        .into_iter()
        .map(|bytes| {
            let mut text = String::new();
            if bytes.starts_with(&[0x1f, 0x8b]) {
                flate2::read::GzDecoder::new(bytes.as_slice()).read_to_string(&mut text).unwrap();
            } else {
                text = String::from_utf8(bytes).unwrap();
            }
            serde_json::from_str(&text).unwrap()
        })
        .collect()
}

// MARK: - Wire format

fn string(value: &Value) -> String {
    value.as_str().unwrap_or_else(|| panic!("expected a string: {value}")).to_owned()
}

fn optional_string(value: &Value, field: &str) -> Option<String> {
    value.get(field).filter(|value| !value.is_null()).map(string)
}

fn optional_f64(value: &Value, field: &str) -> Option<f64> {
    value.get(field).filter(|value| !value.is_null()).map(|value| value.as_f64().unwrap())
}

fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Null => None,
        Value::String(text) if text == "inf" => Some(f64::INFINITY),
        Value::String(text) if text == "-inf" => Some(f64::NEG_INFINITY),
        Value::String(text) if text == "nan" => Some(f64::NAN),
        _ => Some(value.as_f64().unwrap()),
    }
}

fn placement(value: &Value) -> CoreTabPlacement {
    match value.as_str().unwrap() {
        "temporary" => CoreTabPlacement::Temporary,
        "spacePinned" => CoreTabPlacement::SpacePinned,
        "app" => CoreTabPlacement::App,
        other => panic!("placement {other}"),
    }
}

fn entity_type(value: &Value) -> CoreSyncEntityType {
    CoreSyncEntityType::from_raw(value.as_str().unwrap()).unwrap()
}

fn snapshot(value: &Value) -> CoreSessionSnapshot {
    CoreSessionSnapshot {
        spaces: value.get("spaces").map(|spaces| {
            spaces
                .as_array()
                .unwrap()
                .iter()
                .map(|space| CoreSpaceSnapshot {
                    id: string(&space["id"]),
                    title: string(&space["title"]),
                    system_image_name: string(&space["systemImageName"]),
                    is_pinned_section_collapsed: space["isPinnedSectionCollapsed"].as_bool().unwrap(),
                    selected_tab_index: space.get("selectedTabIndex").and_then(Value::as_i64),
                    color_name: optional_string(space, "colorName"),
                    profile_directory: optional_string(space, "profileDirectory"),
                })
                .collect()
        }),
        pinned_tab_folders: value.get("pinnedTabFolders").map(|folders| {
            folders
                .as_array()
                .unwrap()
                .iter()
                .map(|folder| CoreFolderSnapshot {
                    id: string(&folder["id"]),
                    space_id: string(&folder["spaceID"]),
                    parent_folder_id: optional_string(folder, "parentFolderID"),
                    title: string(&folder["title"]),
                    system_image_name: optional_string(folder, "systemImageName"),
                    is_expanded: folder["isExpanded"].as_bool().unwrap(),
                    pinned_sibling_rank: optional_f64(folder, "pinnedSiblingRank"),
                })
                .collect()
        }),
        tabs: value["tabs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|tab| CoreTabSnapshot {
                id: optional_string(tab, "id"),
                url_string: string(&tab["urlString"]),
                pinned_url_string: optional_string(tab, "pinnedURLString"),
                user_title_override: optional_string(tab, "userTitleOverride"),
                placement: placement(&tab["placement"]),
                space_id: optional_string(tab, "spaceID"),
                pinned_folder_id: optional_string(tab, "pinnedFolderID"),
                pinned_sibling_rank: optional_f64(tab, "pinnedSiblingRank"),
                last_activity_timestamp: optional_f64(tab, "lastActivityTimestamp"),
                page_title: optional_string(tab, "pageTitle"),
                system_image_name: optional_string(tab, "systemImageName"),
            })
            .collect(),
    }
}

fn optional_snapshot(value: &Value) -> Option<CoreSessionSnapshot> {
    (!value.is_null()).then(|| snapshot(value))
}

fn change(value: &Value) -> CoreSyncChange {
    let entity_type = entity_type(&value["entityType"]);
    let op = match value["op"].as_str().unwrap() {
        "upsert" => CoreSyncOp::Upsert,
        _ => CoreSyncOp::Delete,
    };
    let data = value.get("data");
    CoreSyncChange {
        entity_type,
        entity_id: string(&value["entityID"]),
        op,
        space_data: data.filter(|_| entity_type == CoreSyncEntityType::Space).map(|data| CoreSyncSpacePayload {
            title: string(&data["title"]),
            system_image_name: string(&data["systemImageName"]),
            rank: data["rank"].as_f64().unwrap(),
            is_pinned_section_collapsed: data["isPinnedSectionCollapsed"].as_bool().unwrap(),
            selected_tab_id: optional_string(data, "selectedTabID"),
        }),
        tab_data: data.filter(|_| entity_type == CoreSyncEntityType::Tab).map(|data| CoreSyncTabPayload {
            space_id: string(&data["spaceID"]),
            placement: placement(&data["placement"]),
            rank: data["rank"].as_f64().unwrap(),
            url_string: string(&data["urlString"]),
            pinned_url_string: optional_string(data, "pinnedURLString"),
            title: optional_string(data, "title"),
            user_title_override: optional_string(data, "userTitleOverride"),
            favicon_url_string: optional_string(data, "faviconURLString"),
            last_activity_at: optional_string(data, "lastActivityAt"),
            pinned_folder_id: optional_string(data, "pinnedFolderID"),
        }),
        folder_data: data.filter(|_| entity_type == CoreSyncEntityType::Folder).map(|data| CoreSyncFolderPayload {
            space_id: string(&data["spaceID"]),
            parent_folder_id: optional_string(data, "parentFolderID"),
            title: string(&data["title"]),
            system_image_name: optional_string(data, "systemImageName"),
            rank: data["rank"].as_f64().unwrap(),
        }),
    }
}

fn changes(value: &Value) -> Vec<CoreSyncChange> {
    value.as_array().unwrap().iter().map(change).collect()
}

fn change_map(value: &Value) -> HashMap<String, CoreSyncChange> {
    value.as_object().unwrap().iter().map(|(key, value)| (key.clone(), change(value))).collect()
}

fn state(value: &Value) -> (HashMap<String, CoreSyncChange>, HashSet<String>) {
    (change_map(&value["values"]), value["deleted"].as_array().unwrap().iter().map(string).collect())
}

fn patch(value: &Value, field: &str) -> CorePatch {
    match value.get(field) {
        None => CorePatch::Unchanged,
        Some(Value::Null) => CorePatch::Clear,
        Some(value) => CorePatch::Set { value: string(value) },
    }
}

fn space_create(data: &Value) -> CoreSyncSpaceCreate {
    CoreSyncSpaceCreate {
        title: string(&data["title"]),
        system_image_name: string(&data["systemImageName"]),
        is_pinned_section_collapsed: data["isPinnedSectionCollapsed"].as_bool().unwrap(),
        selected_tab_id: optional_string(data, "selectedTabID"),
    }
}

fn tab_create(data: &Value) -> CoreSyncTabCreate {
    CoreSyncTabCreate {
        space_id: string(&data["spaceID"]),
        placement: placement(&data["placement"]),
        url_string: string(&data["urlString"]),
        pinned_url_string: optional_string(data, "pinnedURLString"),
        title: optional_string(data, "title"),
        user_title_override: optional_string(data, "userTitleOverride"),
        favicon_url_string: optional_string(data, "faviconURLString"),
        last_activity_at: optional_string(data, "lastActivityAt"),
    }
}

fn space_patch(fields: &Value) -> CoreSyncSpacePatch {
    CoreSyncSpacePatch {
        title: optional_string(fields, "title"),
        system_image_name: optional_string(fields, "systemImageName"),
        is_pinned_section_collapsed: fields.get("isPinnedSectionCollapsed").and_then(Value::as_bool),
        selected_tab_id: patch(fields, "selectedTabID"),
    }
}

fn tab_patch(fields: &Value) -> CoreSyncTabPatch {
    CoreSyncTabPatch {
        url_string: optional_string(fields, "urlString"),
        pinned_url_string: patch(fields, "pinnedURLString"),
        title: patch(fields, "title"),
        user_title_override: patch(fields, "userTitleOverride"),
        favicon_url_string: patch(fields, "faviconURLString"),
        last_activity_at: patch(fields, "lastActivityAt"),
    }
}

fn semantic_operation(value: &Value) -> CoreSemanticOperation {
    let space = value["entityType"] == "space";
    let id = || string(&value["entityID"]);
    let ids = || value["entityIDs"].as_array().unwrap().iter().map(string).collect();
    let before_id = optional_string(value, "beforeID");
    let after_id = optional_string(value, "afterID");
    match (value["kind"].as_str().unwrap(), space) {
        ("create", true) => {
            CoreSemanticOperation::CreateSpace { id: id(), data: space_create(&value["data"]), before_id, after_id }
        }
        ("create", false) => {
            CoreSemanticOperation::CreateTab { id: id(), data: tab_create(&value["data"]), before_id, after_id }
        }
        ("patch", true) => CoreSemanticOperation::PatchSpace { id: id(), fields: space_patch(&value["fields"]) },
        ("patch", false) => CoreSemanticOperation::PatchTab { id: id(), fields: tab_patch(&value["fields"]) },
        ("move", true) => CoreSemanticOperation::MoveSpaces { ids: ids(), before_id, after_id },
        ("move", false) => CoreSemanticOperation::MoveTabs {
            ids: ids(),
            destination: CoreSyncTabDestination {
                space_id: string(&value["destination"]["spaceID"]),
                placement: placement(&value["destination"]["placement"]),
            },
            before_id,
            after_id,
        },
        ("delete", true) => CoreSemanticOperation::DeleteSpace { id: id() },
        ("delete", false) => CoreSemanticOperation::DeleteTab { id: id() },
        (kind, _) => panic!("kind {kind}"),
    }
}

fn reference(value: &Value) -> CoreSyncEntityRef {
    CoreSyncEntityRef::new(entity_type(&value["entityType"]), value["entityID"].as_str().unwrap())
}

fn optional_reference(value: &Value, field: &str) -> Option<CoreSyncEntityRef> {
    value.get(field).filter(|value| !value.is_null()).map(reference)
}

fn destination(value: &Value) -> CoreSyncFolderDestination {
    match value["kind"].as_str().unwrap() {
        "spaces" => CoreSyncFolderDestination::Spaces,
        _ => CoreSyncFolderDestination::Tabs {
            space_id: string(&value["spaceID"]),
            placement: placement(&value["placement"]),
            pinned_folder_id: optional_string(value, "pinnedFolderID"),
        },
    }
}

fn folder_operation(value: &Value) -> CoreFolderOperation {
    let before = optional_reference(value, "before");
    let after = optional_reference(value, "after");
    if value["kind"] == "move" {
        return CoreFolderOperation::Move {
            items: value["items"].as_array().unwrap().iter().map(reference).collect(),
            destination: destination(&value["destination"]),
            before,
            after,
        };
    }
    let id = string(&value["entityID"]);
    let data = &value["data"];
    match (value["kind"].as_str().unwrap(), value["entityType"].as_str().unwrap()) {
        ("create", "space") => CoreFolderOperation::CreateSpace { id, data: space_create(data), before, after },
        ("create", "tab") => CoreFolderOperation::CreateTab {
            id,
            data: CoreSyncFolderTabCreate {
                base: tab_create(data),
                pinned_folder_id: optional_string(data, "pinnedFolderID"),
            },
            before,
            after,
        },
        ("create", "folder") => CoreFolderOperation::CreateFolder {
            id,
            data: CoreSyncFolderCreate {
                space_id: string(&data["spaceID"]),
                parent_folder_id: optional_string(data, "parentFolderID"),
                title: string(&data["title"]),
                system_image_name: optional_string(data, "systemImageName"),
            },
            before,
            after,
        },
        ("patch", "space") => CoreFolderOperation::PatchSpace { id, fields: space_patch(&value["fields"]) },
        ("patch", "tab") => CoreFolderOperation::PatchTab { id, fields: tab_patch(&value["fields"]) },
        ("patch", "folder") => CoreFolderOperation::PatchFolder {
            id,
            fields: CoreSyncFolderPatch {
                title: optional_string(&value["fields"], "title"),
                system_image_name: patch(&value["fields"], "systemImageName"),
            },
        },
        ("delete", "space") => CoreFolderOperation::DeleteSpace { id },
        ("delete", "tab") => CoreFolderOperation::DeleteTab { id },
        ("delete", "folder") => CoreFolderOperation::DeleteFolder { id },
        (kind, entity) => panic!("{kind} {entity}"),
    }
}

fn pending(value: &Value) -> Vec<CoreQueuedMutation> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let payload = &row["payload"];
            match row["version"].as_i64().unwrap() {
                2 => CoreQueuedMutation::Legacy { changes: changes(&payload["changes"]) },
                3 => CoreQueuedMutation::Semantic {
                    operations: payload["operations"].as_array().unwrap().iter().map(semantic_operation).collect(),
                },
                4 => CoreQueuedMutation::Folders {
                    operations: payload["operations"].as_array().unwrap().iter().map(folder_operation).collect(),
                },
                _ => CoreQueuedMutation::Other,
            }
        })
        .collect()
}

fn baseline(value: &Value) -> Baseline {
    Baseline {
        entities: value["entities"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, entity)| {
                (
                    key.clone(),
                    CoreSyncBaselineEntity {
                        server_seq: entity["serverSeq"].as_i64().unwrap(),
                        change: change(&entity["change"]),
                    },
                )
            })
            .collect(),
        deleted: value["deletedKeys"].as_array().unwrap().iter().map(string).collect(),
    }
}

/// The event as the app hands it over: the payload its envelope names.
fn event(value: &Value) -> CoreSyncEvent {
    let op = string(&value["op"]);
    let data = &value["data"];
    let payload = if op == "delete" {
        CoreSyncEventData::Other
    } else {
        match value["entityType"].as_str().unwrap() {
            "space" => CoreSyncEventData::Space {
                data: CoreSyncEventSpaceData {
                    title: optional_string(data, "title"),
                    system_image_name: optional_string(data, "systemImageName"),
                    rank: optional_f64(data, "rank"),
                    is_pinned_section_collapsed: data.get("isPinnedSectionCollapsed").and_then(Value::as_bool),
                    selected_tab_id: optional_string(data, "selectedTabID"),
                },
            },
            "tab" => CoreSyncEventData::Tab {
                data: CoreSyncEventTabData {
                    space_id: optional_string(data, "spaceID"),
                    placement: data.get("placement").map(placement),
                    rank: optional_f64(data, "rank"),
                    url_string: optional_string(data, "urlString"),
                    pinned_url_string: optional_string(data, "pinnedURLString"),
                    title: optional_string(data, "title"),
                    user_title_override: optional_string(data, "userTitleOverride"),
                    favicon_url_string: optional_string(data, "faviconURLString"),
                    last_activity_at: optional_string(data, "lastActivityAt"),
                    pinned_folder_id: optional_string(data, "pinnedFolderID"),
                },
            },
            "folder" => CoreSyncEventData::Folder {
                data: CoreSyncEventFolderData {
                    space_id: optional_string(data, "spaceID"),
                    parent_folder_id: optional_string(data, "parentFolderID"),
                    title: optional_string(data, "title"),
                    system_image_name: optional_string(data, "systemImageName"),
                    rank: optional_f64(data, "rank"),
                },
            },
            _ => CoreSyncEventData::Other,
        }
    };
    CoreSyncEvent {
        server_seq: value["serverSeq"].as_i64().unwrap(),
        entity_type: string(&value["entityType"]),
        entity_id: string(&value["entityID"]),
        op,
        data: payload,
    }
}

// MARK: - Comparison

/// Debug output names every field with its exact bytes and the shortest digits of every number.
fn exact<T: std::fmt::Debug>(value: &T) -> String {
    format!("{value:#?}")
}

fn exact_map(values: &HashMap<String, CoreSyncChange>) -> BTreeMap<&String, String> {
    values.iter().map(|(key, value)| (key, exact(value))).collect()
}

fn sorted(keys: &HashSet<String>) -> Vec<&String> {
    let mut keys: Vec<&String> = keys.iter().collect();
    keys.sort();
    keys
}

fn same_number(left: Option<f64>, right: Option<f64>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => left.to_bits() == right.to_bits() || (left.is_nan() && right.is_nan()),
        (None, None) => true,
        _ => false,
    }
}

// MARK: - Tests

#[test]
fn activity_dates_match_foundation() {
    for fixture in fixtures() {
        for entry in fixture["dates"].as_array().unwrap() {
            if let Some(value) = entry.get("string") {
                let parsed = dates::parse(value.as_str().unwrap());
                assert!(same_number(parsed, number(&entry["timestamp"])), "parse {value}: {parsed:?}");
            } else if let Some(pair) = entry.get("latest") {
                let (current, incoming) = (pair[0].as_str(), pair[1].as_str());
                assert_eq!(dates::latest(current, incoming), entry["result"].as_str(), "latest {pair}");
            } else if let Some(value) = entry.get("projected") {
                let result = dates::projected_timestamp(value.as_str(), number(&entry["local"]));
                assert!(same_number(result, number(&entry["result"])), "projected {entry}: {result:?}");
            } else {
                let seconds = entry["format"].as_f64().unwrap();
                assert_eq!(dates::format(seconds), entry["result"].as_str().unwrap(), "format {seconds}");
            }
        }
    }
}

#[test]
fn projections_match_swift() {
    for fixture in fixtures() {
        let title = fixture["defaultSpaceTitle"].as_str().unwrap();
        for (index, case) in fixture["cases"].as_array().unwrap().iter().enumerate() {
            check_case(index, case, title);
        }
    }
}

fn check_case(index: usize, case: &Value, title: &str) {
    let previous = optional_snapshot(&case["previous"]);
    let next = snapshot(&case["next"]);
    let unchanged = case["unchanged"].as_bool().unwrap();
    let intent: Option<Vec<CoreSyncEntityRef>> =
        (!case["intent"].is_null()).then(|| case["intent"].as_array().unwrap().iter().map(reference).collect());
    let context = |part: &str| format!("case {index}: {part}");

    assert_eq!(
        exact(&outbox::canonical_changes(&next, title)),
        exact(&changes(&case["canonical"])),
        "{}",
        context("canonical")
    );
    assert_eq!(
        exact(&outbox::changes(previous.as_ref(), &next, title)),
        exact(&changes(&case["changes"])),
        "{}",
        context("changes")
    );

    let tab_ids: Option<Vec<String>> = intent.as_ref().map(|items| {
        if unchanged {
            Vec::new()
        } else {
            items
                .iter()
                .filter(|item| item.entity_type == CoreSyncEntityType::Tab)
                .map(|item| item.entity_id.clone())
                .collect()
        }
    });
    let operations = semantic::operations(previous.as_ref(), &next, tab_ids.as_deref(), title);
    let expected: Vec<CoreSemanticOperation> =
        case["semantic"].as_array().unwrap().iter().map(semantic_operation).collect();
    assert_eq!(exact(&operations), exact(&expected), "{}", context("semantic operations"));
    let (mut values, mut deleted) = state(&case["semanticStart"]);
    semantic::apply(&operations, &mut values, &mut deleted);
    let (expected_values, expected_deleted) = state(&case["semanticApplied"]);
    assert_eq!(exact_map(&values), exact_map(&expected_values), "{}", context("semantic replay"));
    assert_eq!(sorted(&deleted), sorted(&expected_deleted), "{}", context("semantic replay tombstones"));

    assert_eq!(
        exact(&folders::canonical_changes(&next, title)),
        exact(&changes(&case["folderCanonical"])),
        "{}",
        context("folder canonical")
    );
    let items: Option<Vec<CoreSyncEntityRef>> =
        intent.as_ref().map(|items| if unchanged { Vec::new() } else { items.clone() });
    let operations = folders::operations(previous.as_ref(), &next, items.as_deref(), title);
    let expected: Vec<CoreFolderOperation> = case["folder"].as_array().unwrap().iter().map(folder_operation).collect();
    assert_eq!(exact(&operations), exact(&expected), "{}", context("folder operations"));
    let (start_values, start_deleted) = state(&case["folderStart"]);
    let (mut values, mut deleted) = (start_values.clone(), start_deleted.clone());
    folders::apply(&operations, &mut values, &mut deleted);
    let (expected_values, expected_deleted) = state(&case["folderApplied"]);
    assert_eq!(exact_map(&values), exact_map(&expected_values), "{}", context("folder replay"));
    assert_eq!(sorted(&deleted), sorted(&expected_deleted), "{}", context("folder replay tombstones"));
    assert_eq!(
        exact(&folders::snapshot(&values, previous.as_ref())),
        exact(&snapshot(&case["folderSnapshot"])),
        "{}",
        context("folder snapshot")
    );
    let adoption = folders::adoption_operations(&next, &start_values, &start_deleted, title);
    let expected: Vec<CoreFolderOperation> =
        case["adoption"].as_array().unwrap().iter().map(folder_operation).collect();
    assert_eq!(exact(&adoption), exact(&expected), "{}", context("adoption"));
    for entry in case["moves"].as_array().unwrap() {
        let items: Vec<CoreSyncEntityRef> = entry["items"].as_array().unwrap().iter().map(reference).collect();
        let result = folders::can_move(&items, &destination(&entry["destination"]), &start_values, &start_deleted);
        assert_eq!(result, entry["result"].as_bool().unwrap(), "{}", context(&format!("can move {entry}")));
    }

    let events: Vec<CoreSyncEvent> = case["events"].as_array().unwrap().iter().map(event).collect();
    let mut applied = Baseline::default();
    let outcome = applied.apply(&events);
    assert_eq!(outcome.is_err(), case["baselineError"].as_bool().unwrap(), "{}", context("baseline error"));
    if outcome.is_ok() {
        let expected = baseline(&case["baselineAfter"]);
        let entities = |baseline: &Baseline| -> BTreeMap<String, String> {
            baseline.entities.iter().map(|(key, entity)| (key.clone(), exact(entity))).collect()
        };
        assert_eq!(entities(&applied), entities(&expected), "{}", context("baseline"));
        assert_eq!(sorted(&applied.deleted), sorted(&expected.deleted), "{}", context("baseline tombstones"));
    }
    let baseline = baseline(&case["baseline"]);
    // The app sends the entities events name and merges the update, as `apply` on the whole baseline.
    let mut split = baseline.clone();
    let named: HashSet<String> =
        events.iter().map(|event| format!("{}:{}", event.entity_type, event.entity_id)).collect();
    let subset = split
        .entities
        .iter()
        .filter(|(key, _)| named.contains(*key))
        .map(|(key, entity)| (key.clone(), entity.clone()))
        .collect();
    let mut whole = baseline.clone();
    match (outbox::baseline_update(subset, &events), whole.apply(&events)) {
        (Ok(update), Ok(())) => {
            split.entities.extend(update.entities);
            split.deleted.extend(update.deleted_keys);
            let entities = |baseline: &Baseline| -> BTreeMap<String, String> {
                baseline.entities.iter().map(|(key, entity)| (key.clone(), exact(entity))).collect()
            };
            assert_eq!(entities(&split), entities(&whole), "{}", context("baseline update"));
            assert_eq!(sorted(&split.deleted), sorted(&whole.deleted), "{}", context("baseline update tombstones"));
        }
        (Err(_), Err(_)) => {}
        _ => panic!("{}", context("baseline update outcome")),
    }
    let queue = pending(&case["pending"]);
    let local = optional_snapshot(&case["local"]);
    let effective = outbox::effective_changes(&baseline, &queue);
    assert_eq!(exact_map(&effective), exact_map(&change_map(&case["effective"])), "{}", context("effective changes"));
    assert_eq!(
        exact(&outbox::snapshot(&effective, local.as_ref())),
        exact(&snapshot(&case["outboxSnapshot"])),
        "{}",
        context("outbox snapshot")
    );
    let projected = outbox::snapshot(&effective, local.as_ref());
    assert!(outbox::identical_snapshots(&projected, &projected.clone()), "{}", context("identical to itself"));
    if let Some(local) = &local {
        assert_eq!(
            outbox::identical_snapshots(&projected, local),
            exact(&projected) == exact(local),
            "{}",
            context("identical to local")
        );
    }
    assert_eq!(
        exact(&folders::snapshot(&effective, local.as_ref())),
        exact(&snapshot(&case["outboxFolderSnapshot"])),
        "{}",
        context("outbox folder snapshot")
    );
    assert_eq!(
        exact(&outbox::rebased_changes(previous.as_ref(), &next, &baseline, &queue, title)),
        exact(&changes(&case["rebased"])),
        "{}",
        context("rebased changes")
    );
    assert_eq!(
        exact(&outbox::removing_deleted_entities(&next, &baseline.deleted)),
        exact(&snapshot(&case["removed"])),
        "{}",
        context("removing deleted entities")
    );
}
