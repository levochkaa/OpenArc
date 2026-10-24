//! Timestamps as the original server returned them: a JavaScript `Date`
//! built from PostgreSQL's text value, which keeps milliseconds only.

use chrono::{DateTime, Datelike, Timelike, Utc};

/// `Date#toISOString()` of the instant node-postgres would have parsed.
pub fn js_iso(timestamp: DateTime<Utc>) -> String {
    // node-postgres turns the fraction into `1000 * parseFloat("0." + digits)`
    // and `Date.UTC` truncates it to whole milliseconds.
    let micros = timestamp.timestamp_subsec_micros().min(999_999);
    let fraction: f64 = format!("0.{micros:06}").parse().unwrap_or(0.0);
    let millis = (fraction * 1000.0).trunc() as u32;
    let year = timestamp.year();
    let year = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else if year < 0 {
        format!("-{:06}", -year)
    } else {
        format!("+{year:06}")
    };
    format!(
        "{year}-{:02}-{:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        timestamp.month(),
        timestamp.day(),
        timestamp.hour(),
        timestamp.minute(),
        timestamp.second()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn keeps_milliseconds_by_truncation() {
        let base = Utc.with_ymd_and_hms(2026, 10, 25, 1, 2, 3).unwrap();
        assert_eq!(js_iso(base), "2026-10-25T01:02:03.000Z");
        assert_eq!(js_iso(base + chrono::Duration::microseconds(123_999)), "2026-10-25T01:02:03.123Z");
        assert_eq!(js_iso(base + chrono::Duration::microseconds(581_000)), "2026-10-25T01:02:03.581Z");
        assert_eq!(js_iso(base + chrono::Duration::microseconds(999)), "2026-10-25T01:02:03.000Z");
    }
}
