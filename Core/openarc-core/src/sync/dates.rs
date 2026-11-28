//! Activity dates on the wire: ISO 8601 strings, compared as instants.
//!
//! `parse` reads a string as `Date.ISO8601FormatStyle().parse` of swift-foundation 6.2 does, the version
//! macOS 26 and iOS 26 ship: as lenient (`2026-02-30`, `T25:00:00`, `GMT+3`, text after the zone), with its
//! Gregorian calendar that counts days before 15 October 1582 in the Julian one, and with the same
//! floating-point steps, so a parsed value is the same `TimeInterval` to the bit. `format` writes what
//! `ISO8601DateFormatter().string(from:)` writes for the date: whole seconds, UTC.

/// Seconds from 1970 to 2001, `Date.timeIntervalBetween1970AndReferenceDate`.
const REFERENCE_DATE_SINCE_1970: f64 = 978_307_200.0;
/// The Julian date of 2001-01-01T00:00:00Z.
const JULIAN_DATE_AT_REFERENCE: f64 = 2_451_910.5;
/// The first Gregorian day, 1582-10-15, as a noon-based Julian day number.
const JULIAN_CUTOVER_DAY: i64 = 2_299_161;

/// The time `value` names, in seconds since 1970, or `None` when it is no ISO 8601 date and time.
pub fn parse(value: &str) -> Option<f64> {
    let mut reader = Reader { bytes: value.as_bytes(), index: 0 };
    if reader.bytes.is_empty() {
        return None;
    }
    let year = reader.digits(None)?;
    reader.expect(b'-')?;
    let month = reader.digits(None)?;
    if !(1..13).contains(&month) {
        return None;
    }
    reader.expect(b'-')?;
    let day = reader.digits(None)?;
    if !(1..32).contains(&day) {
        return None;
    }
    reader.expect(b'T')?;
    let hour = reader.digits(None)?;
    reader.expect(b':')?;
    let minute = reader.digits(None)?;
    reader.expect(b':')?;
    let second = reader.digits(None)?;
    let mut nanosecond = None;
    if reader.peek() == Some(b'.') {
        reader.index += 1;
        nanosecond = Some(reader.nanoseconds()?);
    }
    let offset = reader.time_zone()?;

    // `Calendar.date(from:)` refuses components outside the range it supports.
    if !(-4714..=506_714).contains(&year)
        || !(-4714 * 8760..=i64::from(i32::MAX)).contains(&hour)
        || !(i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&minute)
        || !(i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&second)
    {
        return None;
    }
    let mut julian_day = julian_day_number(day, month, year, false)?;
    if julian_day < JULIAN_CUTOVER_DAY {
        julian_day = julian_day_number(day, month, year, true)?;
    }
    let mut seconds_in_day = 0.0;
    seconds_in_day += hour as f64 * 3600.0;
    seconds_in_day += minute as f64 * 60.0;
    seconds_in_day += second as f64;
    if let Some(nanosecond) = nanosecond {
        seconds_in_day += nanosecond as f64 / 1_000_000_000.0;
    }
    let midnight = (julian_day as f64 - JULIAN_DATE_AT_REFERENCE) * 86_400.0;
    let since_reference = midnight - 43_200.0 + seconds_in_day - offset as f64 - 0.0;
    Some(since_reference + REFERENCE_DATE_SINCE_1970)
}

/// `ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))`: the second it falls in, UTC.
pub fn format(seconds: f64) -> String {
    let since_reference = seconds - REFERENCE_DATE_SINCE_1970;
    let milliseconds = (since_reference + REFERENCE_DATE_SINCE_1970) * 1000.0;
    let whole = (milliseconds / 1000.0).floor() as i64;
    let days = whole.div_euclid(86_400);
    let second_of_day = whole.rem_euclid(86_400);
    // 1970-01-01 is Julian day 2440588.
    let julian_day = days + 2_440_588;
    let (year, month, day) = civil_date(julian_day, julian_day < JULIAN_CUTOVER_DAY);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        second_of_day / 3600,
        second_of_day % 3600 / 60,
        second_of_day % 60
    )
}

/// The later of two activity dates; an unreadable incoming date never replaces a readable one.
pub fn latest<'a>(current: Option<&'a str>, incoming: Option<&'a str>) -> Option<&'a str> {
    let Some(candidate) = incoming.and_then(parse) else {
        return current.filter(|current| parse(current).is_some());
    };
    let Some(previous) = current.and_then(parse) else {
        return incoming;
    };
    if candidate > previous { incoming } else { current }
}

/// The local activity time for a synced date. The wire carries whole seconds: a local time within the
/// same second keeps its fraction; a different date wins.
pub fn projected_timestamp(incoming: Option<&str>, local: Option<f64>) -> Option<f64> {
    let previous = local.filter(|value| value.is_finite());
    let Some(candidate) = incoming.and_then(parse) else {
        return previous;
    };
    if let Some(previous) = previous
        && previous.floor() == candidate
    {
        return Some(previous);
    }
    Some(candidate)
}

#[uniffi::export(name = "core_sync_latest_activity")]
pub fn sync_latest_activity(current: Option<String>, incoming: Option<String>) -> Option<String> {
    latest(current.as_deref(), incoming.as_deref()).map(str::to_owned)
}

#[uniffi::export(name = "core_sync_projected_activity")]
pub fn sync_projected_activity(incoming: Option<String>, local: Option<f64>) -> Option<f64> {
    projected_timestamp(incoming.as_deref(), local)
}

#[uniffi::export(name = "core_sync_format_activity")]
pub fn sync_format_activity(seconds: f64) -> String {
    format(seconds)
}

struct Reader<'a> {
    bytes: &'a [u8],
    index: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.index).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.index += 1;
        Some(byte)
    }

    fn expect(&mut self, byte: u8) -> Option<()> {
        (self.next()? == byte).then_some(())
    }

    /// Up to `max` digits, at most 10, and at least one.
    fn digits(&mut self, max: Option<usize>) -> Option<i64> {
        let max = max.unwrap_or(10).min(10);
        let mut result = 0_i64;
        let mut count = 0;
        while let Some(byte) = self.peek().filter(u8::is_ascii_digit) {
            result = result * 10 + i64::from(byte - b'0');
            self.index += 1;
            count += 1;
            if count >= max {
                break;
            }
        }
        (count > 0).then_some(result)
    }

    /// One to nine fraction digits, as nanoseconds.
    fn nanoseconds(&mut self) -> Option<i64> {
        let start = self.index;
        let value = self.digits(None)?;
        let count = self.index - start;
        (count <= 9).then(|| value * 10_i64.pow(9 - count as u32))
    }

    /// The zone's offset from UTC in seconds: `Z`, `GMT` or `UTC` with an optional offset, or `±hh[[:]mm[[:]ss]]`.
    fn time_zone(&mut self) -> Option<i64> {
        let first = self.next()?;
        if first == b'Z' || first == b'z' {
            return Some(0);
        }
        let positive;
        if first.eq_ignore_ascii_case(&b'G') || first.eq_ignore_ascii_case(&b'U') {
            let rest = if first.eq_ignore_ascii_case(&b'G') { *b"MT" } else { *b"TC" };
            for expected in rest {
                if !self.next()?.eq_ignore_ascii_case(&expected) {
                    return None;
                }
            }
            match self.peek() {
                Some(sign @ (b'+' | b'-')) => {
                    positive = sign == b'+';
                    self.index += 1;
                }
                _ => return Some(0),
            }
        } else if first == b'+' || first == b'-' {
            positive = first == b'+';
        } else {
            return None;
        }
        let hours = self.digits(Some(2))?;
        let expect_minutes = match self.peek() {
            Some(b':') => {
                self.index += 1;
                true
            }
            Some(byte) => byte.is_ascii_digit(),
            None => false,
        };
        let mut offset = hours * 3600;
        if expect_minutes {
            offset += self.digits(Some(2))? * 60;
            if self.peek() == Some(b':') {
                self.index += 1;
            }
            if self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
                offset += self.digits(Some(2))?;
            }
        }
        // `TimeZone(secondsFromGMT:)` accepts offsets up to 18 hours.
        if offset > 18 * 3600 {
            return None;
        }
        Some(if positive { offset } else { -offset })
    }
}

/// The noon-based Julian day number of a date, by E. G. Richards' algorithm (Explanatory Supplement to the
/// Astronomical Almanac, ch. 15), as `_CalendarGregorian.julianDay(ofDay:month:year:)` computes it; `day`
/// may overflow the month.
fn julian_day_number(day: i64, month: i64, year: i64, julian: bool) -> Option<i64> {
    let (y, j, m, n, r, p, s, t, u, a, c): (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) =
        (4716, 1401, 2, 12, 4, 1461, 153, 2, 5, 184, -38);
    // The day before the month starts, then the day itself.
    let h = month - m;
    let g = year.checked_add(y)? - (n - h) / n;
    let f = (h - 1 + n) % n;
    let e = p.checked_mul(g)? / r - 1 - j;
    let start = e + (s * f + t) / u;
    let start = if julian { start } else { start - (3 * ((g + a) / 100)) / 4 - c };
    Some(start + day)
}

/// Year, month and day of a noon-based Julian day number, in the Julian or the Gregorian calendar.
fn civil_date(julian_day: i64, julian: bool) -> (i64, i64, i64) {
    let (y, j, m, n, r, p, v, u, s, w, b, c): (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) =
        (4716, 1401, 2, 12, 4, 1461, 3, 5, 153, 2, 274_277, -38);
    let f = julian_day + j;
    let f = if julian { f } else { f + (((4 * julian_day + b) / 146_097) * 3) / 4 + c };
    let e = r * f + v;
    let g = e.rem_euclid(p) / r;
    let h = u * g + w;
    let day = (h % s).div_euclid(u) + 1;
    let month = (h.div_euclid(s) + m) % n + 1;
    let year = e.div_euclid(p) - y + (n + m - month) / n;
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_foundation_forms() {
        assert_eq!(parse("2026-11-28T10:00:00Z"), Some(1_795_860_000.0));
        assert_eq!(parse("2026-11-28T10:00:00.123Z"), Some(1_795_860_000.123_000_1));
        assert_eq!(parse("2026-11-28T10:00:00+03:00"), Some(1_795_849_200.0));
        assert_eq!(parse("2026-02-30T10:00:00Z"), Some(1_772_445_600.0));
        assert_eq!(parse("0001-01-01T00:00:00Z"), Some(-62_135_769_600.0));
        assert_eq!(parse("2026-11-28T10:00:00.1234567891Z"), None);
        assert_eq!(parse("2026-11-28T10:00:00"), None);
        assert_eq!(parse("2026-11-28T10:00:00+23:59"), None);
    }

    #[test]
    fn writes_whole_utc_seconds() {
        assert_eq!(format(1_764_000_000.999), "2025-11-24T16:00:00Z");
        assert_eq!(format(-0.25), "1969-12-31T23:59:59Z");
        assert_eq!(format(253_402_300_800.0), "10000-01-01T00:00:00Z");
        assert_eq!(format(-62_135_596_800.0), "0001-01-03T00:00:00Z");
    }
}
