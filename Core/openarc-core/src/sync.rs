//! The sync protocol's versions and limits, from `openarc-sync-protocol`, which the server shares.

use openarc_sync_protocol as protocol;

/// Push protocol versions this client and the server know.
#[uniffi::export(name = "core_sync_supported_push_versions")]
pub fn sync_supported_push_versions() -> Vec<u32> {
    protocol::SUPPORTED_PUSH_VERSIONS.iter().map(|&version| u32::from(version)).collect()
}

/// Whether automatic expiry may use `seconds` as its inactivity interval.
#[uniffi::export(name = "core_is_sync_expiry_interval")]
pub fn is_sync_expiry_interval(seconds: i64) -> bool {
    u64::try_from(seconds).is_ok_and(protocol::is_expiry_interval)
}

/// Limits the server applies to a boost, in UTF-16 code units.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncBoostLimits {
    pub host: u32,
    pub code: u32,
    pub selector: u32,
    pub selector_count: u32,
    pub title: u32,
}

#[uniffi::export(name = "core_sync_boost_limits")]
pub fn sync_boost_limits() -> CoreSyncBoostLimits {
    CoreSyncBoostLimits {
        host: protocol::BOOST_HOST_LIMIT as u32,
        code: protocol::BOOST_CODE_LIMIT as u32,
        selector: protocol::BOOST_SELECTOR_LIMIT as u32,
        selector_count: protocol::BOOST_SELECTOR_COUNT_LIMIT as u32,
        title: protocol::BOOST_TITLE_LIMIT as u32,
    }
}
