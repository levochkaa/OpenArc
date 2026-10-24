//! Request validation with the semantics of the original Zod schemas.
//!
//! Parsing returns the normalized value: defaults applied, unknown keys of
//! non-strict objects stripped, every number a double. Mutation receipt
//! digests are computed from that value, so it must match what the original
//! server stored. The first union option without issues wins; a union whose
//! options all fail reports the issues of its only non-aborted option, or
//! "Invalid input".

use crate::js_json;
use regex::Regex;
use serde_json::{Map, Value};
use std::sync::LazyLock;

pub const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Issue {
    pub path: Vec<String>,
    pub message: String,
    /// Type and value mismatches stop a union from reporting this option's issues.
    pub aborts: bool,
}

impl Issue {
    pub fn custom(path: &[&str], message: &str) -> Self {
        Self {
            path: path.iter().map(|segment| (*segment).to_string()).collect(),
            message: message.to_string(),
            aborts: false,
        }
    }
}

/// `path: message` joined by `; `, with `body` for the root.
pub fn format_issues(issues: &[Issue]) -> String {
    issues
        .iter()
        .map(|issue| {
            let path = if issue.path.is_empty() { "body".to_string() } else { issue.path.join(".") };
            format!("{path}: {}", issue.message)
        })
        .collect::<Vec<_>>()
        .join("; ")
}

pub type Check = fn(&Value, &mut Vec<Issue>);

#[derive(Clone, Copy, Debug)]
pub enum Format {
    Uuid,
    DateTime,
}

pub enum Schema {
    String {
        min: Option<usize>,
        max: Option<usize>,
        format: Option<Format>,
    },
    Number {
        int: bool,
        min: Option<(f64, bool)>,
        max: Option<(f64, bool)>,
    },
    Boolean,
    Literal(Value),
    Enum(&'static [&'static str]),
    Nullable(Box<Schema>),
    Optional(Box<Schema>),
    Default(Box<Schema>, Value),
    /// The key must be absent.
    Undefined,
    Object {
        fields: Vec<(&'static str, Schema)>,
        strict: bool,
    },
    Array {
        item: Box<Schema>,
        min: Option<usize>,
        max: Option<usize>,
    },
    Union(Vec<Schema>),
    /// A union chosen by the literal value of one key.
    Discriminated {
        key: &'static str,
        options: Vec<Schema>,
    },
    /// Runs the check on the parsed value unless parsing aborted.
    Refined(Box<Schema>, Check),
}

pub struct Outcome {
    pub value: Option<Value>,
    pub issues: Vec<Issue>,
}

impl Outcome {
    fn aborted(&self) -> bool {
        self.issues.iter().any(|issue| issue.aborts)
    }
}

impl Schema {
    /// The normalized value, or every issue found.
    pub fn parse(&self, input: &Value) -> Result<Value, Vec<Issue>> {
        let outcome = self.run(Some(input));
        if outcome.issues.is_empty() { Ok(outcome.value.unwrap_or(Value::Null)) } else { Err(outcome.issues) }
    }

    fn run(&self, input: Option<&Value>) -> Outcome {
        match self {
            Self::Optional(inner) => match input {
                None => Outcome { value: None, issues: Vec::new() },
                Some(value) => inner.run(Some(value)),
            },
            Self::Default(inner, default) => match input {
                None => Outcome { value: Some(normalize_number(default.clone())), issues: Vec::new() },
                Some(value) => inner.run(Some(value)),
            },
            Self::Undefined => match input {
                None => Outcome { value: None, issues: Vec::new() },
                Some(value) => invalid_type("undefined", Some(value)),
            },
            Self::Nullable(inner) => match input {
                Some(Value::Null) => Outcome { value: Some(Value::Null), issues: Vec::new() },
                other => inner.run(other),
            },
            Self::String { min, max, format } => {
                let Some(Value::String(text)) = input else { return invalid_type("string", input) };
                let mut issues = Vec::new();
                let length = text.encode_utf16().count();
                if let Some(min) = min
                    && length < *min
                {
                    issues.push(check(format!("Too small: expected string to have >={min} characters")));
                }
                if let Some(max) = max
                    && length > *max
                {
                    issues.push(check(format!("Too big: expected string to have <={max} characters")));
                }
                match format {
                    Some(Format::Uuid) if !UUID.is_match(text) => issues.push(check("Invalid UUID".to_string())),
                    Some(Format::DateTime) if !DATE_TIME.is_match(text) => {
                        issues.push(check("Invalid ISO datetime".to_string()));
                    }
                    _ => {}
                }
                Outcome { value: Some(Value::String(text.clone())), issues }
            }
            Self::Number { int, min, max } => {
                let Some(Value::Number(number)) = input else { return invalid_type("number", input) };
                let value = number.as_f64().unwrap_or(f64::NAN);
                if !value.is_finite() {
                    return invalid_type("number", input);
                }
                let mut issues = Vec::new();
                if *int {
                    if value.fract() != 0.0 {
                        return Outcome {
                            value: Some(js_json::number(value)),
                            issues: vec![Issue {
                                path: Vec::new(),
                                message: "Invalid input: expected int, received number".to_string(),
                                aborts: true,
                            }],
                        };
                    }
                    if value.abs() > MAX_SAFE_INTEGER {
                        let bound = if value > 0.0 { "<=9007199254740991" } else { ">=-9007199254740991" };
                        issues.push(check(format!(
                            "Too {}: expected int to be {bound}",
                            if value > 0.0 { "big" } else { "small" }
                        )));
                    }
                }
                if let Some((bound, inclusive)) = min
                    && (value < *bound || (!inclusive && value == *bound))
                {
                    let operator = if *inclusive { ">=" } else { ">" };
                    issues.push(check(format!(
                        "Too small: expected number to be {operator}{}",
                        js_json::stringify(&js_json::number(*bound))
                    )));
                }
                if let Some((bound, inclusive)) = max
                    && (value > *bound || (!inclusive && value == *bound))
                {
                    let operator = if *inclusive { "<=" } else { "<" };
                    issues.push(check(format!(
                        "Too big: expected number to be {operator}{}",
                        js_json::stringify(&js_json::number(*bound))
                    )));
                }
                Outcome { value: Some(js_json::number(value)), issues }
            }
            Self::Boolean => match input {
                Some(Value::Bool(value)) => Outcome { value: Some(Value::Bool(*value)), issues: Vec::new() },
                other => invalid_type("boolean", other),
            },
            Self::Literal(expected) => {
                let matches = match (input, expected) {
                    (Some(Value::Number(actual)), Value::Number(expected)) => actual.as_f64() == expected.as_f64(),
                    (Some(actual), expected) => actual == expected,
                    (None, _) => false,
                };
                if matches {
                    Outcome { value: Some(normalize_number(expected.clone())), issues: Vec::new() }
                } else {
                    Outcome {
                        value: None,
                        issues: vec![Issue {
                            path: Vec::new(),
                            message: format!("Invalid input: expected {}", js_json::stringify(expected)),
                            aborts: true,
                        }],
                    }
                }
            }
            Self::Enum(options) => match input {
                Some(Value::String(text)) if options.contains(&text.as_str()) => {
                    Outcome { value: Some(Value::String(text.clone())), issues: Vec::new() }
                }
                _ => Outcome {
                    value: None,
                    issues: vec![Issue {
                        path: Vec::new(),
                        message: format!(
                            "Invalid option: expected one of {}",
                            options.iter().map(|option| format!("\"{option}\"")).collect::<Vec<_>>().join("|")
                        ),
                        aborts: true,
                    }],
                },
            },
            Self::Object { fields, strict } => {
                let Some(Value::Object(map)) = input else { return invalid_type("object", input) };
                let mut output = Map::new();
                let mut issues = Vec::new();
                for (key, schema) in fields {
                    let outcome = schema.run(map.get(*key));
                    issues.extend(prefixed(key, outcome.issues));
                    if let Some(value) = outcome.value {
                        output.insert((*key).to_string(), value);
                    }
                }
                if *strict {
                    let unknown: Vec<&String> =
                        map.keys().filter(|key| !fields.iter().any(|(field, _)| field == key)).collect();
                    if !unknown.is_empty() {
                        let names = unknown.iter().map(|key| format!("\"{key}\"")).collect::<Vec<_>>().join(", ");
                        let noun = if unknown.len() == 1 { "key" } else { "keys" };
                        issues.push(Issue {
                            path: Vec::new(),
                            message: format!("Unrecognized {noun}: {names}"),
                            aborts: true,
                        });
                    }
                }
                Outcome { value: Some(Value::Object(output)), issues }
            }
            Self::Array { item, min, max } => {
                let Some(Value::Array(items)) = input else { return invalid_type("array", input) };
                let mut output = Vec::with_capacity(items.len());
                let mut issues = Vec::new();
                for (index, value) in items.iter().enumerate() {
                    let outcome = item.run(Some(value));
                    issues.extend(prefixed(&index.to_string(), outcome.issues));
                    output.push(outcome.value.unwrap_or(Value::Null));
                }
                if let Some(min) = min
                    && items.len() < *min
                {
                    issues.push(check(format!("Too small: expected array to have >={min} items")));
                }
                if let Some(max) = max
                    && items.len() > *max
                {
                    issues.push(check(format!("Too big: expected array to have <={max} items")));
                }
                Outcome { value: Some(Value::Array(output)), issues }
            }
            Self::Union(options) => {
                let mut results = Vec::with_capacity(options.len());
                for option in options {
                    let outcome = option.run(input);
                    if outcome.issues.is_empty() {
                        return outcome;
                    }
                    results.push(outcome);
                }
                let mut live = results.into_iter().filter(|outcome| !outcome.aborted()).collect::<Vec<_>>();
                if live.len() == 1 {
                    return live.remove(0);
                }
                Outcome {
                    value: None,
                    issues: vec![Issue { path: Vec::new(), message: "Invalid input".to_string(), aborts: true }],
                }
            }
            Self::Discriminated { key, options } => {
                let Some(Value::Object(map)) = input else { return invalid_type("object", input) };
                let discriminator = map.get(*key);
                let option = options.iter().find(|option| {
                    let Self::Object { fields, .. } = option.unrefined() else { return false };
                    fields.iter().any(|(field, schema)| {
                        field == key
                            && match (schema, discriminator) {
                                (Self::Literal(expected), Some(actual)) => expected == actual,
                                (Self::Enum(values), Some(Value::String(actual))) => values.contains(&actual.as_str()),
                                _ => false,
                            }
                    })
                });
                match option {
                    Some(option) => option.run(input),
                    None => Outcome {
                        value: None,
                        issues: vec![Issue {
                            path: vec![(*key).to_string()],
                            message: "Invalid input".to_string(),
                            aborts: true,
                        }],
                    },
                }
            }
            Self::Refined(inner, refine) => {
                let mut outcome = inner.run(input);
                if !outcome.aborted()
                    && let Some(value) = &outcome.value
                {
                    refine(value, &mut outcome.issues);
                }
                outcome
            }
        }
    }

    fn unrefined(&self) -> &Schema {
        match self {
            Self::Refined(inner, _) => inner.unrefined(),
            other => other,
        }
    }
}

fn check(message: String) -> Issue {
    Issue { path: Vec::new(), message, aborts: false }
}

fn prefixed(segment: &str, issues: Vec<Issue>) -> impl Iterator<Item = Issue> + '_ {
    issues.into_iter().map(move |mut issue| {
        issue.path.insert(0, segment.to_string());
        issue
    })
}

fn invalid_type(expected: &str, input: Option<&Value>) -> Outcome {
    let received = match input {
        None => "undefined",
        Some(Value::Null) => "null",
        Some(Value::Bool(_)) => "boolean",
        Some(Value::Number(_)) => "number",
        Some(Value::String(_)) => "string",
        Some(Value::Array(_)) => "array",
        Some(Value::Object(_)) => "object",
    };
    Outcome {
        value: None,
        issues: vec![Issue {
            path: Vec::new(),
            message: format!("Invalid input: expected {expected}, received {received}"),
            aborts: true,
        }],
    }
}

fn normalize_number(value: Value) -> Value {
    match value {
        Value::Number(number) => js_json::number(number.as_f64().unwrap_or(f64::NAN)),
        other => other,
    }
}

/// RFC 9562 UUIDs, plus the nil and max UUIDs.
static UUID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        "^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\
         |00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$",
    )
    .expect("valid regex")
});

/// ISO 8601 date and time in UTC (`Z`), seconds and fraction optional.
static DATE_TIME: LazyLock<Regex> = LazyLock::new(|| {
    let date = "(?:(?:[0-9][0-9][2468][048]|[0-9][0-9][13579][26]|[0-9][0-9]0[48]|[02468][048]00|[13579][26]00)-02-29\
                |[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)\
                |(?:02)-(?:0[1-9]|1[0-9]|2[0-8])))";
    let time = "(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\\.[0-9]+)?)?";
    Regex::new(&format!("^{date}T(?:{time}(?:Z))$")).expect("valid regex")
});

// MARK: Builders

pub fn string() -> Schema {
    Schema::String { min: None, max: None, format: None }
}

pub fn string_between(min: Option<usize>, max: Option<usize>) -> Schema {
    Schema::String { min, max, format: None }
}

pub fn non_empty() -> Schema {
    string_between(Some(1), None)
}

pub fn uuid() -> Schema {
    Schema::String { min: None, max: None, format: Some(Format::Uuid) }
}

pub fn date_time() -> Schema {
    Schema::String { min: None, max: None, format: Some(Format::DateTime) }
}

pub fn number() -> Schema {
    Schema::Number { int: false, min: None, max: None }
}

pub fn integer(min: Option<(f64, bool)>, max: Option<(f64, bool)>) -> Schema {
    Schema::Number { int: true, min, max }
}

pub fn literal(value: Value) -> Schema {
    Schema::Literal(value)
}

pub fn options(values: &'static [&'static str]) -> Schema {
    Schema::Enum(values)
}

pub fn nullable(inner: Schema) -> Schema {
    Schema::Nullable(Box::new(inner))
}

pub fn optional(inner: Schema) -> Schema {
    Schema::Optional(Box::new(inner))
}

pub fn with_default(inner: Schema, value: Value) -> Schema {
    Schema::Default(Box::new(inner), value)
}

pub fn object(fields: Vec<(&'static str, Schema)>) -> Schema {
    Schema::Object { fields, strict: false }
}

pub fn strict(fields: Vec<(&'static str, Schema)>) -> Schema {
    Schema::Object { fields, strict: true }
}

pub fn array(item: Schema, min: Option<usize>, max: Option<usize>) -> Schema {
    Schema::Array { item: Box::new(item), min, max }
}

pub fn refined(inner: Schema, check: Check) -> Schema {
    Schema::Refined(Box::new(inner), check)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn uuid_requires_an_rfc_9562_version_and_variant() {
        assert!(UUID.is_match("550e8400-e29b-41d4-a716-446655440000"));
        assert!(UUID.is_match("00000000-0000-0000-0000-000000000000"));
        assert!(!UUID.is_match("550e8400-e29b-01d4-a716-446655440000"));
        assert!(!UUID.is_match("550e8400-e29b-41d4-c716-446655440000"));
        assert!(!UUID.is_match("550e8400e29b41d4a716446655440000"));
        assert!(!UUID.is_match("{550e8400-e29b-41d4-a716-446655440000}"));
    }

    #[test]
    fn date_time_accepts_utc_with_optional_seconds_and_fraction() {
        for valid in
            ["2026-01-02T03:04Z", "2026-01-02T03:04:05Z", "2026-01-02T03:04:05.123456789Z", "2024-02-29T00:00Z"]
        {
            assert!(DATE_TIME.is_match(valid), "{valid}");
        }
        for invalid in [
            "2026-01-02T03:04:05+00:00",
            "2026-01-02 03:04:05Z",
            "2026-02-30T00:00Z",
            "2023-02-29T00:00Z",
            "2026-01-02T24:00Z",
            "2026-01-02T03:04:05.Z",
            "２０２６-01-02T03:04Z",
        ] {
            assert!(!DATE_TIME.is_match(invalid), "{invalid}");
        }
    }

    #[test]
    fn objects_strip_or_reject_unknown_keys_and_apply_defaults() {
        let loose = object(vec![("a", with_default(Schema::Boolean, json!(false))), ("b", optional(number()))]);
        assert_eq!(loose.parse(&json!({"x": 1})).unwrap(), json!({"a": false}));
        let tight = strict(vec![("a", optional(number()))]);
        assert_eq!(format_issues(&tight.parse(&json!({"x": 1})).unwrap_err()), "body: Unrecognized key: \"x\"");
    }

    #[test]
    fn unions_report_the_only_option_that_got_past_its_types() {
        let schema = Schema::Union(vec![
            strict(vec![("v", literal(json!(5))), ("n", integer(Some((0.0, true)), None))]),
            object(vec![("v", Schema::Undefined), ("n", integer(Some((0.0, true)), None))]),
        ]);
        assert_eq!(
            format_issues(&schema.parse(&json!({"n": -1})).unwrap_err()),
            "n: Too small: expected number to be >=0"
        );
        assert_eq!(schema.parse(&json!({"v": 5, "n": 2})).unwrap(), json!({"v": 5.0, "n": 2.0}));
        assert_eq!(format_issues(&schema.parse(&json!({"v": 4})).unwrap_err()), "body: Invalid input");
    }
}
