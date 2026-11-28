//! The session and the sync protocol's records, as the projections read and write them. The apps keep
//! their own types for storage and the wire and convert at the boundary. Equality is Swift's: strings by
//! canonical equivalence (`text::same`), numbers by value.

use std::collections::HashMap;

use super::text::{same, same_option};

/// The Space every tab without a Space belongs to.
pub const DEFAULT_SPACE_ID: &str = "default-space";
/// The icon of that Space.
pub const DEFAULT_SPACE_ICON: &str = "square.grid.2x2";

#[uniffi::export(name = "core_default_space_id")]
pub fn default_space_id() -> String {
    DEFAULT_SPACE_ID.to_owned()
}

#[uniffi::export(name = "core_default_space_icon")]
pub fn default_space_icon() -> String {
    DEFAULT_SPACE_ICON.to_owned()
}

// MARK: - The session

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreTabPlacement {
    Temporary,
    SpacePinned,
    App,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSpaceSnapshot {
    pub id: String,
    pub title: String,
    pub system_image_name: String,
    pub is_pinned_section_collapsed: bool,
    pub selected_tab_index: Option<i64>,
    /// Local, like the tab's page title: never synced.
    pub color_name: Option<String>,
    pub profile_directory: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreFolderSnapshot {
    pub id: String,
    pub space_id: String,
    pub parent_folder_id: Option<String>,
    pub title: String,
    pub system_image_name: Option<String>,
    pub is_expanded: bool,
    pub pinned_sibling_rank: Option<f64>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreTabSnapshot {
    pub id: Option<String>,
    pub url_string: String,
    pub pinned_url_string: Option<String>,
    pub user_title_override: Option<String>,
    pub placement: CoreTabPlacement,
    pub space_id: Option<String>,
    pub pinned_folder_id: Option<String>,
    pub pinned_sibling_rank: Option<f64>,
    pub last_activity_timestamp: Option<f64>,
    /// Local display data: never synced.
    pub page_title: Option<String>,
    pub system_image_name: Option<String>,
}

/// A window's Spaces, pinned folders and tabs. Split View groups stay with the app.
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSessionSnapshot {
    pub spaces: Option<Vec<CoreSpaceSnapshot>>,
    pub pinned_tab_folders: Option<Vec<CoreFolderSnapshot>>,
    pub tabs: Vec<CoreTabSnapshot>,
}

// MARK: - Canonical entities

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreSyncEntityType {
    Space,
    Tab,
    Folder,
}

impl CoreSyncEntityType {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Space => "space",
            Self::Tab => "tab",
            Self::Folder => "folder",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "space" => Some(Self::Space),
            "tab" => Some(Self::Tab),
            "folder" => Some(Self::Folder),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreSyncOp {
    Upsert,
    Delete,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncSpacePayload {
    pub title: String,
    pub system_image_name: String,
    pub rank: f64,
    pub is_pinned_section_collapsed: bool,
    pub selected_tab_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncTabPayload {
    pub space_id: String,
    pub placement: CoreTabPlacement,
    pub rank: f64,
    pub url_string: String,
    pub pinned_url_string: Option<String>,
    pub title: Option<String>,
    pub user_title_override: Option<String>,
    pub favicon_url_string: Option<String>,
    pub last_activity_at: Option<String>,
    pub pinned_folder_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncFolderPayload {
    pub space_id: String,
    pub parent_folder_id: Option<String>,
    pub title: String,
    pub system_image_name: Option<String>,
    pub rank: f64,
}

/// One entity's state: an upsert with its payload, or a delete.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncChange {
    pub entity_type: CoreSyncEntityType,
    pub entity_id: String,
    pub op: CoreSyncOp,
    pub space_data: Option<CoreSyncSpacePayload>,
    pub tab_data: Option<CoreSyncTabPayload>,
    pub folder_data: Option<CoreSyncFolderPayload>,
}

impl CoreSyncChange {
    pub fn space(id: &str, data: CoreSyncSpacePayload) -> Self {
        Self {
            entity_type: CoreSyncEntityType::Space,
            entity_id: id.to_owned(),
            op: CoreSyncOp::Upsert,
            space_data: Some(data),
            tab_data: None,
            folder_data: None,
        }
    }

    pub fn tab(id: &str, data: CoreSyncTabPayload) -> Self {
        Self {
            entity_type: CoreSyncEntityType::Tab,
            entity_id: id.to_owned(),
            op: CoreSyncOp::Upsert,
            space_data: None,
            tab_data: Some(data),
            folder_data: None,
        }
    }

    pub fn folder(id: &str, data: CoreSyncFolderPayload) -> Self {
        Self {
            entity_type: CoreSyncEntityType::Folder,
            entity_id: id.to_owned(),
            op: CoreSyncOp::Upsert,
            space_data: None,
            tab_data: None,
            folder_data: Some(data),
        }
    }

    pub fn deleted(entity_type: CoreSyncEntityType, id: &str) -> Self {
        Self {
            entity_type,
            entity_id: id.to_owned(),
            op: CoreSyncOp::Delete,
            space_data: None,
            tab_data: None,
            folder_data: None,
        }
    }

    /// The entity's sibling rank. Folders rank 0 here, as in the v3 lists that do not hold them.
    pub fn space_or_tab_rank(&self) -> Option<f64> {
        self.space_data.as_ref().map(|data| data.rank).or(self.tab_data.as_ref().map(|data| data.rank))
    }
}

/// The key of an entity in a map of changes: `type:id`.
pub fn key(entity_type: CoreSyncEntityType, id: &str) -> String {
    format!("{}:{id}", entity_type.raw())
}

pub fn key_of(change: &CoreSyncChange) -> String {
    key(change.entity_type, &change.entity_id)
}

#[uniffi::export(name = "core_sync_key")]
pub fn sync_key(entity_type: CoreSyncEntityType, id: String) -> String {
    key(entity_type, &id)
}

/// Canonical values with queued operations applied, and the keys hidden so far.
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncReplayState {
    pub values: HashMap<String, CoreSyncChange>,
    pub deleted: Vec<String>,
}

// MARK: - Operations

/// A patch field: left out, set, or cleared with an explicit null.
#[derive(Clone, Debug, Default, uniffi::Enum)]
pub enum CorePatch {
    #[default]
    Unchanged,
    Set {
        value: String,
    },
    Clear,
}

impl CorePatch {
    pub fn from(previous: Option<&str>, next: Option<&str>) -> Self {
        if same_option(previous, next) {
            Self::Unchanged
        } else {
            next.map_or(Self::Clear, |value| Self::Set { value: value.to_owned() })
        }
    }

    pub fn applied(&self, value: Option<&str>) -> Option<String> {
        match self {
            Self::Unchanged => value.map(str::to_owned),
            Self::Set { value } => Some(value.clone()),
            Self::Clear => None,
        }
    }

    pub fn is_unchanged(&self) -> bool {
        matches!(self, Self::Unchanged)
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncSpaceCreate {
    pub title: String,
    pub system_image_name: String,
    pub is_pinned_section_collapsed: bool,
    pub selected_tab_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncTabCreate {
    pub space_id: String,
    pub placement: CoreTabPlacement,
    pub url_string: String,
    pub pinned_url_string: Option<String>,
    pub title: Option<String>,
    pub user_title_override: Option<String>,
    pub favicon_url_string: Option<String>,
    pub last_activity_at: Option<String>,
}

#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncSpacePatch {
    pub title: Option<String>,
    pub system_image_name: Option<String>,
    pub is_pinned_section_collapsed: Option<bool>,
    pub selected_tab_id: CorePatch,
}

impl CoreSyncSpacePatch {
    pub fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.system_image_name.is_none()
            && self.is_pinned_section_collapsed.is_none()
            && self.selected_tab_id.is_unchanged()
    }
}

#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncTabPatch {
    pub url_string: Option<String>,
    pub pinned_url_string: CorePatch,
    pub title: CorePatch,
    pub user_title_override: CorePatch,
    pub favicon_url_string: CorePatch,
    pub last_activity_at: CorePatch,
}

impl CoreSyncTabPatch {
    pub fn is_empty(&self) -> bool {
        self.url_string.is_none()
            && self.pinned_url_string.is_unchanged()
            && self.title.is_unchanged()
            && self.user_title_override.is_unchanged()
            && self.favicon_url_string.is_unchanged()
            && self.last_activity_at.is_unchanged()
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncTabDestination {
    pub space_id: String,
    pub placement: CoreTabPlacement,
}

/// A protocol version 3 operation.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreSemanticOperation {
    CreateSpace {
        id: String,
        data: CoreSyncSpaceCreate,
        before_id: Option<String>,
        after_id: Option<String>,
    },
    CreateTab {
        id: String,
        data: CoreSyncTabCreate,
        before_id: Option<String>,
        after_id: Option<String>,
    },
    PatchSpace {
        id: String,
        fields: CoreSyncSpacePatch,
    },
    PatchTab {
        id: String,
        fields: CoreSyncTabPatch,
    },
    MoveSpaces {
        ids: Vec<String>,
        before_id: Option<String>,
        after_id: Option<String>,
    },
    MoveTabs {
        ids: Vec<String>,
        destination: CoreSyncTabDestination,
        before_id: Option<String>,
        after_id: Option<String>,
    },
    DeleteSpace {
        id: String,
    },
    DeleteTab {
        id: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CoreSyncEntityRef {
    pub entity_type: CoreSyncEntityType,
    pub entity_id: String,
}

impl CoreSyncEntityRef {
    pub fn new(entity_type: CoreSyncEntityType, id: &str) -> Self {
        Self { entity_type, entity_id: id.to_owned() }
    }

    pub fn of(change: &CoreSyncChange) -> Self {
        Self::new(change.entity_type, &change.entity_id)
    }

    pub fn key(&self) -> String {
        key(self.entity_type, &self.entity_id)
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncFolderTabCreate {
    pub base: CoreSyncTabCreate,
    pub pinned_folder_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSyncFolderCreate {
    pub space_id: String,
    pub parent_folder_id: Option<String>,
    pub title: String,
    pub system_image_name: Option<String>,
}

#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct CoreSyncFolderPatch {
    pub title: Option<String>,
    pub system_image_name: CorePatch,
}

impl CoreSyncFolderPatch {
    pub fn is_empty(&self) -> bool {
        self.title.is_none() && self.system_image_name.is_unchanged()
    }
}

/// Where a version 4 move puts its items: the Space list, or one tab list.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreSyncFolderDestination {
    Spaces,
    Tabs { space_id: String, placement: CoreTabPlacement, pinned_folder_id: Option<String> },
}

/// A protocol version 4 operation.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreFolderOperation {
    CreateSpace {
        id: String,
        data: CoreSyncSpaceCreate,
        before: Option<CoreSyncEntityRef>,
        after: Option<CoreSyncEntityRef>,
    },
    CreateTab {
        id: String,
        data: CoreSyncFolderTabCreate,
        before: Option<CoreSyncEntityRef>,
        after: Option<CoreSyncEntityRef>,
    },
    CreateFolder {
        id: String,
        data: CoreSyncFolderCreate,
        before: Option<CoreSyncEntityRef>,
        after: Option<CoreSyncEntityRef>,
    },
    PatchSpace {
        id: String,
        fields: CoreSyncSpacePatch,
    },
    PatchTab {
        id: String,
        fields: CoreSyncTabPatch,
    },
    PatchFolder {
        id: String,
        fields: CoreSyncFolderPatch,
    },
    Move {
        items: Vec<CoreSyncEntityRef>,
        destination: CoreSyncFolderDestination,
        before: Option<CoreSyncEntityRef>,
        after: Option<CoreSyncEntityRef>,
    },
    DeleteSpace {
        id: String,
    },
    DeleteTab {
        id: String,
    },
    DeleteFolder {
        id: String,
    },
}

/// A queued push row, as far as the projection replays it.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreQueuedMutation {
    /// Version 2: full records.
    Legacy { changes: Vec<CoreSyncChange> },
    /// Version 3.
    Semantic { operations: Vec<CoreSemanticOperation> },
    /// Version 4.
    Folders { operations: Vec<CoreFolderOperation> },
    /// Expiry, boost and mobile tab rows, which leave the Spaces alone.
    Other,
}

// MARK: - Swift equality

impl PartialEq for CoreSyncSpacePayload {
    fn eq(&self, other: &Self) -> bool {
        same(&self.title, &other.title)
            && same(&self.system_image_name, &other.system_image_name)
            && self.rank == other.rank
            && self.is_pinned_section_collapsed == other.is_pinned_section_collapsed
            && same_option(self.selected_tab_id.as_deref(), other.selected_tab_id.as_deref())
    }
}

impl PartialEq for CoreSyncTabPayload {
    fn eq(&self, other: &Self) -> bool {
        same(&self.space_id, &other.space_id)
            && self.placement == other.placement
            && self.rank == other.rank
            && same(&self.url_string, &other.url_string)
            && same_option(self.pinned_url_string.as_deref(), other.pinned_url_string.as_deref())
            && same_option(self.title.as_deref(), other.title.as_deref())
            && same_option(self.user_title_override.as_deref(), other.user_title_override.as_deref())
            && same_option(self.favicon_url_string.as_deref(), other.favicon_url_string.as_deref())
            && same_option(self.last_activity_at.as_deref(), other.last_activity_at.as_deref())
            && same_option(self.pinned_folder_id.as_deref(), other.pinned_folder_id.as_deref())
    }
}

impl PartialEq for CoreSyncFolderPayload {
    fn eq(&self, other: &Self) -> bool {
        same(&self.space_id, &other.space_id)
            && same_option(self.parent_folder_id.as_deref(), other.parent_folder_id.as_deref())
            && same(&self.title, &other.title)
            && same_option(self.system_image_name.as_deref(), other.system_image_name.as_deref())
            && self.rank == other.rank
    }
}

impl PartialEq for CoreSyncChange {
    fn eq(&self, other: &Self) -> bool {
        self.entity_type == other.entity_type
            && same(&self.entity_id, &other.entity_id)
            && self.op == other.op
            && self.space_data == other.space_data
            && self.tab_data == other.tab_data
            && self.folder_data == other.folder_data
    }
}
