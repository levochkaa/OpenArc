//! URL components parsed and rebuilt by RFC 3986, with the rules of Apple's `URLComponents`: characters a
//! component does not allow are percent-encoded, a non-ASCII host is IDNA-encoded, and a valid address stays
//! byte for byte as it was typed. Addresses the apps stored and compared before the core moved to Rust have
//! this form, so every platform keeps it.

use super::idna;
use std::ops::Range;

/// The ASCII characters each component allows, one bit per character.
mod mask {
    pub const SCHEME: u128 = 0x07ff_fffe_07ff_fffe_03ff_6800_0000_0000;
    pub const USER: u128 = 0x47ff_fffe_87ff_fffe_2bff_7fd2_0000_0000;
    pub const PASSWORD: u128 = USER;
    pub const HOST_IPV_FUTURE: u128 = 0x47ff_fffe_87ff_fffe_2fff_7fd2_0000_0000;
    pub const HOST: u128 = 0x47ff_fffe_87ff_fffe_2bff_7fd2_0000_0000;
    pub const HOST_ZONE_ID: u128 = 0x47ff_fffe_87ff_fffe_03ff_6000_0000_0000;
    pub const PATH: u128 = 0x47ff_fffe_87ff_ffff_2fff_ffd2_0000_0000;
    pub const PATH_FIRST_SEGMENT: u128 = 0x47ff_fffe_87ff_ffff_2bff_ffd2_0000_0000;
    pub const QUERY: u128 = 0x47ff_fffe_87ff_ffff_afff_ffd2_0000_0000;
    pub const FRAGMENT: u128 = QUERY;
    pub const QUERY_ITEM: u128 = 0x47ff_fffe_87ff_ffff_8fff_ff92_0000_0000;
}

/// Schemes whose hosts are percent-encoded rather than IDNA-encoded.
const SCHEMES_TO_PERCENT_ENCODE_HOST: &[&str] = &[
    "tel",
    "telemergencycall",
    "telprompt",
    "callto",
    "facetime",
    "facetime-prompt",
    "facetime-audio",
    "facetime-audio-prompt",
    "imap",
    "pop",
    "addressbook",
    "contact",
    "phasset",
    "http+unix",
    "https+unix",
    "ws+unix",
    "wss+unix",
];

fn allows(mask: u128, byte: u8) -> bool {
    byte < 128 && mask & (1u128 << byte) != 0
}

fn validate(bytes: &[u8], mask: u128, percent_encoding_allowed: bool) -> bool {
    if !percent_encoding_allowed {
        return bytes.iter().all(|&byte| allows(mask, byte));
    }
    let mut hex_digits_required = 0;
    for &byte in bytes {
        if byte >= 128 {
            return false;
        }
        if byte == b'%' {
            if hex_digits_required != 0 {
                return false;
            }
            hex_digits_required = 2;
        } else if !allows(mask, byte) {
            return false;
        } else if hex_digits_required > 0 {
            if !byte.is_ascii_hexdigit() {
                return false;
            }
            hex_digits_required -= 1;
        }
    }
    hex_digits_required == 0
}

fn validate_scheme(scheme: &[u8]) -> bool {
    scheme.first().is_some_and(|&first| first >= b'A') && validate(scheme, mask::SCHEME, false)
}

fn looks_like_ip_literal(host: &[u8]) -> bool {
    host.first() == Some(&b'[') && host.last() == Some(&b']')
}

/// An IP literal's address, then an optional zone ID after "%25".
fn validate_ip_literal_host(host: &[u8]) -> bool {
    let inner = &host[1..host.len() - 1];
    let Some(percent) = inner.iter().position(|&byte| byte == b'%') else {
        return validate(inner, mask::HOST_IPV_FUTURE, false);
    };
    if inner.get(percent + 1) != Some(&b'2') || inner.get(percent + 2) != Some(&b'5') {
        return false;
    }
    validate(&inner[..percent], mask::HOST_IPV_FUTURE, false)
        && validate(&inner[percent + 3..], mask::HOST_ZONE_ID, true)
}

fn validate_host(host: &[u8], known_ip_literal: bool) -> bool {
    if known_ip_literal || looks_like_ip_literal(host) {
        return looks_like_ip_literal(host) && validate_ip_literal_host(host);
    }
    validate(host, mask::HOST, true)
}

fn validate_port(port: &[u8], scheme: Option<&[u8]>) -> bool {
    port.iter().all(u8::is_ascii_digit) || scheme == Some(b"addressbook".as_slice())
}

const HEX: &[u8; 16] = b"0123456789ABCDEF";

fn percent_encode(text: &[u8], mask: u128) -> String {
    let mut output = String::with_capacity(text.len());
    for &byte in text {
        if allows(mask, byte) {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0xF) as usize] as char);
        }
    }
    output
}

fn percent_encode_path(path: &[u8]) -> String {
    match path.iter().position(|&byte| byte == b'/') {
        None => percent_encode(path, mask::PATH_FIRST_SEGMENT),
        Some(0) => percent_encode(path, mask::PATH),
        Some(slash) => {
            percent_encode(&path[..slash], mask::PATH_FIRST_SEGMENT) + &percent_encode(&path[slash..], mask::PATH)
        }
    }
}

/// The text with every valid `%XX` decoded, or `None` when a `%` is not followed by two hex digits or the
/// bytes are not UTF-8. Bytes in `excluding` keep their escape.
pub(crate) fn percent_decode(text: &str, excluding: &[u8]) -> Option<String> {
    let bytes = text.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = hex_value(*bytes.get(index + 1)?)?;
            let low = hex_value(*bytes.get(index + 2)?)?;
            let byte = high << 4 | low;
            if excluding.contains(&byte) {
                output.extend_from_slice(&bytes[index..index + 3]);
            } else {
                output.push(byte);
            }
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    (byte as char).to_digit(16).map(|value| value as u8)
}

fn should_percent_encode_host(host: &[u8], scheme: Option<&str>) -> bool {
    if looks_like_ip_literal(host) {
        return true;
    }
    scheme.is_some_and(|scheme| SCHEMES_TO_PERCENT_ENCODE_HOST.iter().any(|known| known.eq_ignore_ascii_case(scheme)))
}

fn percent_encode_host(host: &[u8]) -> Option<String> {
    if host.is_empty() {
        return Some(String::new());
    }
    if !looks_like_ip_literal(host) {
        return Some(percent_encode(host, mask::HOST));
    }
    let Some(percent) = host.iter().position(|&byte| byte == b'%') else {
        return validate_host(host, true).then(|| String::from_utf8_lossy(host).into_owned());
    };
    let zone = percent_encode(&host[percent..host.len() - 1], mask::HOST_ZONE_ID);
    Some(format!("{}{zone}]", String::from_utf8_lossy(&host[..percent])))
}

// MARK: - Parsing

/// Byte ranges of each component in `string`. The path always exists, possibly empty.
#[derive(Clone, Debug, Default)]
struct ParseInfo {
    string: String,
    scheme: Option<Range<usize>>,
    user: Option<Range<usize>>,
    password: Option<Range<usize>>,
    host: Option<Range<usize>>,
    port: Option<Range<usize>>,
    path: Range<usize>,
    query: Option<Range<usize>>,
    fragment: Option<Range<usize>>,
    is_ip_literal: bool,
    did_percent_encode_host: bool,
}

impl ParseInfo {
    fn part(&self, range: &Option<Range<usize>>) -> Option<&str> {
        range.as_ref().map(|range| &self.string[range.clone()])
    }

    fn has_authority(&self) -> bool {
        self.user.is_some() || self.password.is_some() || self.host.is_some() || self.port.is_some()
    }

    fn port_number(&self) -> Option<i64> {
        self.part(&self.port).and_then(|port| port.parse().ok())
    }
}

/// Splits the string by RFC 3986 delimiters, without encoding anything.
fn split_parts(string: String) -> Option<ParseInfo> {
    let buffer = string.as_bytes();
    let mut info = ParseInfo::default();
    if buffer.is_empty() {
        info.string = string;
        return Some(info);
    }
    let end = buffer.len();
    let mut current = 0;

    while current != end {
        let byte = buffer[current];
        if byte == b':' {
            // A scheme has at least one character; otherwise this is a relative reference.
            if current != 0 {
                info.scheme = Some(0..current);
                current += 1;
                if current == end {
                    if !validate_scheme(&buffer[0..current - 1]) {
                        return None;
                    }
                    info.path = end..end;
                    info.string = string;
                    return Some(info);
                }
            }
            break;
        } else if matches!(byte, b'/' | b'?' | b'#' | b'[' | b']' | b'@') {
            // "[", "]" and "@" mean the text starts with an authority, which a port may follow.
            current = 0;
            break;
        }
        current += 1;
    }
    if let Some(scheme) = &info.scheme
        && !validate_scheme(&buffer[scheme.clone()])
    {
        return None;
    }
    if current == end {
        current = 0;
    }

    if current + 1 < end && buffer[current] == b'/' && buffer[current + 1] == b'/' {
        current += 2;
        let authority_start = current;
        while current != end && !matches!(buffer[current], b'/' | b'?' | b'#') {
            current += 1;
        }
        if authority_start == current {
            info.host = Some(current..current);
        } else {
            if !split_authority(buffer, authority_start..current, &mut info) {
                return None;
            }
            if let Some(port) = &info.port {
                let scheme = info.scheme.as_ref().map(|scheme| &buffer[scheme.clone()]);
                if !validate_port(&buffer[port.clone()], scheme) {
                    return None;
                }
            }
        }
    }

    let path_start = current;
    while current != end && !matches!(buffer[current], b'?' | b'#') {
        current += 1;
    }
    info.path = path_start..current;

    if current != end {
        if buffer[current] == b'?' {
            let query_start = current + 1;
            if let Some(pound) = buffer[query_start..].iter().position(|&byte| byte == b'#') {
                info.query = Some(query_start..query_start + pound);
                info.fragment = Some(query_start + pound + 1..end);
            } else {
                info.query = Some(query_start..end);
            }
        } else {
            info.fragment = Some(current + 1..end);
        }
    }
    info.string = string;
    Some(info)
}

fn split_authority(buffer: &[u8], authority: Range<usize>, info: &mut ParseInfo) -> bool {
    let mut host_start = authority.start;
    let mut host_end = authority.end;
    if let Some(at) = buffer[authority.clone()].iter().rposition(|&byte| byte == b'@') {
        let at = authority.start + at;
        if let Some(colon) = buffer[authority.start..at].iter().position(|&byte| byte == b':') {
            let colon = authority.start + colon;
            info.user = Some(authority.start..colon);
            info.password = Some(colon + 1..at);
        } else {
            info.user = Some(authority.start..at);
        }
        host_start = at + 1;
    }

    let bracket_end = (host_start != authority.end && buffer[host_start] == b'[')
        .then(|| buffer[host_start..authority.end].iter().position(|&byte| byte == b']'))
        .flatten();
    if let Some(bracket_end) = bracket_end {
        info.is_ip_literal = true;
        host_end = host_start + bracket_end + 1;
        if host_end != authority.end {
            if buffer[host_end] != b':' {
                return false;
            }
            info.port = Some(host_end + 1..authority.end);
        }
    } else if let Some(colon) = buffer[host_start..authority.end].iter().position(|&byte| byte == b':') {
        let colon = host_start + colon;
        host_end = colon;
        // An empty port is left out.
        if colon + 1 != authority.end {
            info.port = Some(colon + 1..authority.end);
        }
    }
    info.host = Some(host_start..host_end);
    info.did_percent_encode_host = buffer[host_start..host_end].contains(&b'%');
    true
}

#[derive(Clone, Copy, PartialEq)]
enum Part {
    User,
    Password,
    Host,
    Path,
    Query,
    Fragment,
}

fn invalid_parts(info: &ParseInfo) -> Vec<Part> {
    let mut invalid = Vec::new();
    let bytes = |range: &Option<Range<usize>>| info.part(range).map(str::as_bytes);
    if bytes(&info.user).is_some_and(|user| !validate(user, mask::USER, true)) {
        invalid.push(Part::User);
    }
    if bytes(&info.password).is_some_and(|password| !validate(password, mask::PASSWORD, true)) {
        invalid.push(Part::Password);
    }
    if bytes(&info.host).is_some_and(|host| !validate_host(host, info.is_ip_literal)) {
        invalid.push(Part::Host);
    }
    if !validate(info.string[info.path.clone()].as_bytes(), mask::PATH, true) {
        invalid.push(Part::Path);
    }
    if bytes(&info.query).is_some_and(|query| !validate(query, mask::QUERY, true)) {
        invalid.push(Part::Query);
    }
    if bytes(&info.fragment).is_some_and(|fragment| !validate(fragment, mask::FRAGMENT, true)) {
        invalid.push(Part::Fragment);
    }
    invalid
}

/// Parses the string and encodes the components that are not valid as typed.
fn parse(string: &str) -> Option<ParseInfo> {
    let info = split_parts(string.to_owned())?;
    let invalid = invalid_parts(&info);
    if invalid.is_empty() {
        return Some(info);
    }
    let encoded = |part: Part, text: &str, mask: u128| {
        if invalid.contains(&part) { percent_encode(text.as_bytes(), mask) } else { text.to_owned() }
    };

    let mut result = String::new();
    if let Some(scheme) = info.part(&info.scheme) {
        result += scheme;
        result.push(':');
    }
    if info.has_authority() {
        result += "//";
    }
    if let Some(user) = info.part(&info.user) {
        result += &encoded(Part::User, user, mask::USER);
        if let Some(password) = info.part(&info.password) {
            result.push(':');
            result += &encoded(Part::Password, password, mask::PASSWORD);
        }
        result.push('@');
    }
    if let Some(host) = info.part(&info.host) {
        if !invalid.contains(&Part::Host) {
            result += host;
        } else if info.is_ip_literal || should_percent_encode_host(host.as_bytes(), info.part(&info.scheme)) {
            let encoded_host = percent_encode_host(host.as_bytes())?;
            if info.is_ip_literal && !validate_host(encoded_host.as_bytes(), true) {
                return None;
            }
            result += &encoded_host;
        } else {
            match idna::encode(host) {
                Some(encoded_host) if validate_host(encoded_host.as_bytes(), false) => result += &encoded_host,
                _ => return None,
            }
        }
    }
    if let Some(port) = info.port_number() {
        result += &format!(":{port}");
    }
    let path = &info.string[info.path.clone()];
    result += &if invalid.contains(&Part::Path) { percent_encode_path(path.as_bytes()) } else { path.to_owned() };
    if let Some(query) = info.part(&info.query) {
        result.push('?');
        result += &encoded(Part::Query, query, mask::QUERY);
    }
    if let Some(fragment) = info.part(&info.fragment) {
        result.push('#');
        result += &encoded(Part::Fragment, fragment, mask::FRAGMENT);
    }
    split_parts(result)
}

// MARK: - Components

/// A query item as the query spells it, still percent-encoded.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct QueryItem {
    pub name: String,
    pub value: Option<String>,
}

/// Mutable URL components. Unchanged components keep the parsed text; `string()` rebuilds the address.
#[derive(Clone, Debug, Default)]
pub(crate) struct UrlComponents {
    parsed: Option<ParseInfo>,
    changed: bool,
    scheme: Option<Option<String>>,
    user: Option<Option<String>>,
    password: Option<Option<String>>,
    host: Option<Option<String>>,
    port: Option<Option<i64>>,
    path: Option<String>,
    query: Option<Option<String>>,
    fragment: Option<Option<String>>,
    did_percent_encode_host: bool,
    did_set_invalid_host: bool,
}

impl UrlComponents {
    /// Components with no parts, to fill in.
    pub fn new() -> Self {
        Self { changed: true, ..Self::default() }
    }

    pub fn parse(string: &str) -> Option<Self> {
        let parsed = parse(string)?;
        let did_percent_encode_host = parsed.did_percent_encode_host;
        Some(Self { parsed: Some(parsed), did_percent_encode_host, ..Self::default() })
    }

    fn parsed_part(&self, pick: impl Fn(&ParseInfo) -> &Option<Range<usize>>) -> Option<String> {
        let parsed = self.parsed.as_ref()?;
        parsed.part(pick(parsed)).map(str::to_owned)
    }

    pub fn scheme(&self) -> Option<String> {
        match &self.scheme {
            Some(scheme) => scheme.clone(),
            None => self.parsed_part(|parsed| &parsed.scheme),
        }
    }

    /// Sets a valid scheme; an invalid one leaves the components as they were. Returns whether it was set.
    pub fn set_scheme(&mut self, scheme: &str) -> bool {
        if !validate_scheme(scheme.as_bytes()) {
            return false;
        }
        self.changed = true;
        self.scheme = Some(Some(scheme.to_owned()));
        if self.encoded_host().is_some() {
            // The scheme decides how the host is encoded.
            let host = self.host();
            self.set_host(host.as_deref());
        }
        true
    }

    fn percent_encoded_user(&self) -> Option<String> {
        let user = match &self.user {
            Some(user) => user.clone(),
            None => self.parsed_part(|parsed| &parsed.user),
        };
        user.or_else(|| self.percent_encoded_password().map(|_| String::new()))
    }

    fn percent_encoded_password(&self) -> Option<String> {
        match &self.password {
            Some(password) => password.clone(),
            None => self.parsed_part(|parsed| &parsed.password),
        }
    }

    fn encoded_host(&self) -> Option<String> {
        let host = match &self.host {
            Some(host) => host.clone(),
            None => self.parsed_part(|parsed| &parsed.host),
        };
        host.or_else(|| (self.port().is_some() || self.percent_encoded_user().is_some()).then(String::new))
    }

    /// The host, percent-decoded or IDNA-decoded.
    pub fn host(&self) -> Option<String> {
        let encoded = self.encoded_host()?;
        if encoded.is_empty() {
            return Some(encoded);
        }
        if self.did_percent_encode_host { percent_decode(&encoded, &[0]) } else { idna::decode(&encoded) }
    }

    pub fn set_host(&mut self, host: Option<&str>) {
        self.changed = true;
        self.did_percent_encode_host = false;
        self.did_set_invalid_host = false;
        let Some(host) = host else {
            self.host = Some(None);
            return;
        };
        if validate_host(host.as_bytes(), false) {
            self.host = Some(Some(host.to_owned()));
            self.did_percent_encode_host = host.contains('%');
            return;
        }
        if should_percent_encode_host(host.as_bytes(), self.scheme().as_deref()) {
            match percent_encode_host(host.as_bytes()) {
                Some(encoded) => {
                    self.host = Some(Some(encoded));
                    self.did_percent_encode_host = true;
                }
                None => {
                    self.host = Some(None);
                    self.did_set_invalid_host = true;
                }
            }
            return;
        }
        if let Some(encoded) = idna::encode(host)
            && validate_host(encoded.as_bytes(), false)
        {
            self.host = Some(Some(encoded));
            return;
        }
        self.did_set_invalid_host = true;
        self.host = Some(percent_encode_host(host.as_bytes()));
        self.did_percent_encode_host = true;
    }

    pub fn port(&self) -> Option<i64> {
        match self.port {
            Some(port) => port,
            None => self.parsed.as_ref().and_then(ParseInfo::port_number),
        }
    }

    fn percent_encoded_path(&self) -> String {
        match &self.path {
            Some(path) => path.clone(),
            None => {
                self.parsed.as_ref().map(|parsed| parsed.string[parsed.path.clone()].to_owned()).unwrap_or_default()
            }
        }
    }

    /// The path, percent-decoded.
    pub fn path(&self) -> String {
        percent_decode(&self.percent_encoded_path(), &[]).unwrap_or_default()
    }

    pub fn set_path(&mut self, path: &str) {
        self.changed = true;
        self.path = Some(percent_encode_path(path.as_bytes()));
    }

    pub fn percent_encoded_query(&self) -> Option<String> {
        match &self.query {
            Some(query) => query.clone(),
            None => self.parsed_part(|parsed| &parsed.query),
        }
    }

    fn percent_encoded_fragment(&self) -> Option<String> {
        match &self.fragment {
            Some(fragment) => fragment.clone(),
            None => self.parsed_part(|parsed| &parsed.fragment),
        }
    }

    /// The query split at "&" and each item's first "=", still percent-encoded.
    pub fn percent_encoded_query_items(&self) -> Option<Vec<QueryItem>> {
        let query = self.percent_encoded_query()?;
        if query.is_empty() {
            return Some(Vec::new());
        }
        Some(
            query
                .split('&')
                .map(|item| match item.split_once('=') {
                    Some((name, value)) => QueryItem { name: name.to_owned(), value: Some(value.to_owned()) },
                    None => QueryItem { name: item.to_owned(), value: None },
                })
                .collect(),
        )
    }

    /// Replaces the query with items that are already percent-encoded.
    pub fn set_percent_encoded_query_items(&mut self, items: Option<&[QueryItem]>) {
        self.changed = true;
        self.query = Some(items.map(|items| {
            items
                .iter()
                .map(|item| match &item.value {
                    Some(value) => format!("{}={value}", item.name),
                    None => item.name.clone(),
                })
                .collect::<Vec<_>>()
                .join("&")
        }));
    }

    /// Replaces the query with items, percent-encoding what a query item does not allow.
    pub fn set_query_items(&mut self, items: &[(&str, Option<&str>)]) {
        let encode = |text: &str| {
            if validate(text.as_bytes(), mask::QUERY_ITEM, false) {
                text.to_owned()
            } else {
                percent_encode(text.as_bytes(), mask::QUERY_ITEM)
            }
        };
        let items: Vec<QueryItem> =
            items.iter().map(|(name, value)| QueryItem { name: encode(name), value: value.map(encode) }).collect();
        self.set_percent_encoded_query_items(Some(&items));
    }

    fn has_authority(&self) -> bool {
        self.encoded_host().is_some()
            || self.port().is_some()
            || self.percent_encoded_user().is_some()
            || self.percent_encoded_password().is_some()
    }

    /// The address the components spell, or `None` when they do not form one.
    pub fn string(&self) -> Option<String> {
        if !self.changed {
            return self.parsed.as_ref().map(|parsed| parsed.string.clone());
        }
        if self.did_set_invalid_host {
            return None;
        }
        let path = self.percent_encoded_path();
        let mut result = String::new();
        if let Some(scheme) = self.scheme() {
            result += &scheme;
            result.push(':');
        }
        if self.has_authority() {
            if path.as_bytes().first().is_some_and(|&first| first != b'/') {
                return None;
            }
            result += "//";
        } else if path.starts_with("//") {
            // A path that starts with "//" would read as an authority.
            return None;
        }
        let user = self.percent_encoded_user();
        let password = self.percent_encoded_password();
        if let Some(user) = &user {
            result += user;
        }
        if let Some(password) = &password {
            result.push(':');
            result += password;
        }
        if user.is_some() || password.is_some() {
            result.push('@');
        }
        if let Some(host) = self.encoded_host() {
            result += &host;
        }
        if let Some(port) = self.port() {
            result += &format!(":{port}");
        } else if self.port.is_none()
            && let Some(port) = self.parsed_part(|parsed| &parsed.port)
        {
            result.push(':');
            result += &port;
        }
        if result.is_empty() {
            result += &path_without_colon(&path);
        } else {
            result += &path;
        }
        if let Some(query) = self.percent_encoded_query() {
            result.push('?');
            result += &query;
        }
        if let Some(fragment) = self.percent_encoded_fragment() {
            result.push('#');
            result += &fragment;
        }
        Some(result)
    }
}

/// A colon in a relative path's first segment would read as a scheme separator, so it is encoded.
fn path_without_colon(path: &str) -> String {
    let first = path.bytes().find(|&byte| byte == b':' || byte == b'/');
    if first != Some(b':') || path.starts_with(':') {
        return path.to_owned();
    }
    let slash = path.find('/').unwrap_or(path.len());
    path[..slash].replace(':', "%3A") + &path[slash..]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_a_valid_address_as_typed() {
        let components = UrlComponents::parse("HTTPS://Example.COM:8080/Path?q=a+b#Top").unwrap();
        assert_eq!(components.string().as_deref(), Some("HTTPS://Example.COM:8080/Path?q=a+b#Top"));
        assert_eq!(components.host().as_deref(), Some("Example.COM"));
        assert_eq!(components.port(), Some(8080));
    }

    #[test]
    fn encodes_invalid_characters_per_component() {
        let components = UrlComponents::parse("https://example.com/a b?q=a b#f g").unwrap();
        assert_eq!(components.string().as_deref(), Some("https://example.com/a%20b?q=a%20b#f%20g"));
    }

    #[test]
    fn idna_encodes_a_non_ascii_host() {
        let components = UrlComponents::parse("https://яндекс.рф/").unwrap();
        assert_eq!(components.string().as_deref(), Some("https://xn--d1acpjx3f.xn--p1ai/"));
        assert_eq!(components.host().as_deref(), Some("яндекс.рф"));
    }

    #[test]
    fn rejects_an_invalid_scheme() {
        assert!(UrlComponents::parse("1http://example.com").is_none());
    }

    #[test]
    fn builds_query_items() {
        let mut components = UrlComponents::new();
        components.set_scheme("https");
        components.set_host(Some("www.google.com"));
        components.set_path("/search");
        components.set_query_items(&[("q", Some("c++ & go?"))]);
        assert_eq!(components.string().as_deref(), Some("https://www.google.com/search?q=c++%20%26%20go?"));
    }
}
