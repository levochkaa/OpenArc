//! JSON text exactly as JavaScript's `JSON.stringify` writes it.
//!
//! Mutation receipts store a SHA-256 digest of the canonical request content.
//! The original server computed it in JavaScript, so numbers, string escapes
//! and key order must match byte for byte or stored receipts stop matching
//! their retries.

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;

/// `JSON.stringify(value)`: object keys in insertion order, numbers in
/// ECMAScript `Number#toString` form, strings escaped as JavaScript does.
pub fn stringify(value: &Value) -> String {
    let mut output = String::new();
    write_value(&mut output, value);
    output
}

/// `JSON.stringify(value)` byte length, as `Buffer.byteLength` counts it.
pub fn byte_length(value: &Value) -> usize {
    stringify(value).len()
}

/// The receipt digest input: object keys sorted by UTF-16 code units,
/// recursively; arrays keep their order.
pub fn canonical(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|(a, _), (b, _)| compare_utf16(a, b));
            let mut sorted = Map::new();
            for (key, value) in entries {
                sorted.insert(key.clone(), canonical(value));
            }
            Value::Object(sorted)
        }
        other => other.clone(),
    }
}

/// Hex SHA-256 of the canonical JavaScript JSON text.
pub fn digest(value: &Value) -> String {
    hex::encode(Sha256::digest(stringify(&canonical(value)).as_bytes()))
}

/// JavaScript's `<` on strings: UTF-16 code unit order.
pub fn compare_utf16(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// A JSON number as JavaScript holds it: every number is a double.
pub fn number(value: f64) -> Value {
    serde_json::Number::from_f64(value).map_or(Value::Null, Value::Number)
}

fn write_value(output: &mut String, value: &Value) {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(true) => output.push_str("true"),
        Value::Bool(false) => output.push_str("false"),
        Value::Number(number) => write_number(output, number.as_f64().unwrap_or(f64::NAN)),
        Value::String(string) => write_string(output, string),
        Value::Array(items) => {
            output.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_value(output, item);
            }
            output.push(']');
        }
        Value::Object(map) => {
            output.push('{');
            for (index, (key, value)) in map.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_string(output, key);
                output.push(':');
                write_value(output, value);
            }
            output.push('}');
        }
    }
}

fn write_number(output: &mut String, value: f64) {
    if !value.is_finite() {
        // JSON.stringify writes NaN and Infinity as null.
        output.push_str("null");
        return;
    }
    if value == 0.0 {
        // Including -0, which JavaScript writes as 0.
        output.push('0');
        return;
    }
    let mut buffer = ryu_js::Buffer::new();
    output.push_str(buffer.format_finite(value));
}

fn write_string(output: &mut String, value: &str) {
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\u{08}' => output.push_str("\\b"),
            '\u{0C}' => output.push_str("\\f"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if (character as u32) < 0x20 => {
                output.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => output.push(character),
        }
    }
    output.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_follow_ecmascript_number_to_string() {
        let cases = [
            (1.0, "1"),
            (-0.0, "0"),
            (0.1, "0.1"),
            (1e21, "1e+21"),
            (1e-7, "1e-7"),
            (0.000001, "0.000001"),
            (123456789012345680000.0, "123456789012345680000"),
            (1.5e3, "1500"),
            (0.30000000000000004, "0.30000000000000004"),
            (-2.5, "-2.5"),
        ];
        for (value, expected) in cases {
            assert_eq!(stringify(&number(value)), expected, "{value}");
        }
        assert_eq!(stringify(&json!(9007199254740991_u64)), "9007199254740991");
    }

    #[test]
    fn strings_escape_like_json_stringify() {
        let value = json!("a\"b\\c/d\u{1}\u{8}\u{c}\n\r\t\u{1f}\u{7f}\u{2028}тест😀");
        assert_eq!(stringify(&value), "\"a\\\"b\\\\c/d\\u0001\\b\\f\\n\\r\\t\\u001f\u{7f}\u{2028}тест😀\"");
    }

    #[test]
    fn canonical_sorts_keys_recursively_and_keeps_arrays() {
        let value = json!({"b": [{"z": 1, "a": 2}], "a": null});
        assert_eq!(stringify(&canonical(&value)), r#"{"a":null,"b":[{"a":2,"z":1}]}"#);
    }

    #[test]
    fn utf16_order_differs_from_byte_order_above_the_bmp() {
        // U+FF61 sorts after U+1F600 in UTF-8 bytes but before it in UTF-16.
        assert_eq!(compare_utf16("\u{1F600}", "\u{FF61}"), Ordering::Less);
        assert_eq!("\u{1F600}".cmp("\u{FF61}"), Ordering::Greater);
    }
}
