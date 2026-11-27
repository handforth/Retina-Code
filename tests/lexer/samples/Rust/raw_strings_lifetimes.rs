//! Crate-level doc comment: Rust lexer stress sample.
//! Raw strings, byte strings, lifetimes vs chars, attributes, macros, nested comments.
#![cfg(test)]
#![allow(dead_code, unused_variables)]
#![cfg_attr(feature = "nightly", feature(never_type))]

/* Rust block comments nest: /* inner /* deeper */ */ still outer
   and this line is still a comment */
const AFTER_NESTED: &str = "visible";

/** Outer block doc comment */
/*! Inner block doc comment */

use std::collections::{BTreeMap, HashMap};
use std::fmt::{self, Display, Formatter};
use std::borrow::Cow;

// Strings
const S1: &str = "double \"quoted\" with \\ and \n and \t and \r and \0";
const S2: &str = "hex \x41 and unicode \u{1F600} and \u{41}";
const S3: &str = "string with a line continuation \
                  that skips leading whitespace";
const S4: &str = "multi-line
string literal";
const S5: &str = "trailing backslash \\";
const S6: &str = "// not a comment /* nor this */";
const UNTERMINATED: &str = "this one never closes
const AFTER: i32 = 1;

// Raw strings
const R1: &str = r"raw: \n is literal, so is \";
const R2: &str = r#"raw with "quotes" inside"#;
const R3: &str = r##"raw with "# inside and "## only at the end"##;
const R4: &str = r###"
multi-line raw
with "## and "# that do not close
"###;
const R5: &str = r"";
const R6: &str = r#""#;

// Byte strings and C strings
const B1: &[u8] = b"bytes \x00\xFF \n \\";
const B2: &[u8] = br"raw bytes \n";
const B3: &[u8] = br#"raw bytes with "quotes""#;
const B4: &[u8; 3] = b"abc";
const BC: u8 = b'a';
const BC2: u8 = b'\'';
const BC3: u8 = b'\x7F';
const C1: &std::ffi::CStr = c"C string";
const C2: &std::ffi::CStr = cr#"raw C string"#;

// Chars vs lifetimes
const CH1: char = 'a';
const CH2: char = '\'';
const CH3: char = '\\';
const CH4: char = '\n';
const CH5: char = '\u{1F600}';
const CH6: char = '"';
const CH7: char = '😀';
const CH8: char = '\x41';

struct Parser<'a, 'b: 'a, T: 'a + ?Sized> {
    input: &'a str,
    rest: &'b [u8],
    data: &'a T,
    _marker: std::marker::PhantomData<&'static ()>,
}

impl<'a, 'b: 'a, T> Parser<'a, 'b, T>
where
    T: Display + ?Sized + 'a,
{
    fn peek(&self) -> Option<char> {
        self.input.chars().next()
    }

    fn take_while<F>(&mut self, mut pred: F) -> &'a str
    where
        F: FnMut(char) -> bool,
    {
        let end = self.input.char_indices().find(|&(_, c)| !pred(c)).map_or(self.input.len(), |(i, _)| i);
        let (head, tail) = self.input.split_at(end);
        self.input = tail;
        head
    }
}

fn longest<'x>(a: &'x str, b: &'x str) -> &'x str {
    if a.len() > b.len() { a } else { b }
}

fn char_then_lifetime<'c>(c: char, s: &'c str) -> (&'c str, char) {
    let quote = '\'';
    let lt: &'c str = s;
    (lt, if c == 'x' { quote } else { 'y' })
}

'outer: loop {
    'inner: for i in 0..10 {
        if i == 5 { break 'outer; }
        if i % 2 == 0 { continue 'inner; }
    }
}

// Numbers
const N: [i64; 12] = [1_000_000, 0xFF_FF, 0o17, 0b1010_1010, 10i64, 255, 0x7F, 1, 2, 3, 4, 5];
const U: u8 = 10u8;
const I: i128 = -170_141_183_460_469_231_731_687_303_715_884_105_728i128;
const F1: f32 = 1.0f32;
const F2: f64 = 1.5e-3;
const F3: f64 = 2.5E+10_f64;
const F4: f64 = 1e10;
const F5: f64 = 0.1;
const TUPLE_IDX: i32 = ((1, 2), 3).0.1;
const RANGE: std::ops::Range<i32> = 1..10;
const METHOD_ON_INT: u32 = 5u32.pow(2);

// Attributes
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
#[cfg(all(unix, not(target_os = "macos")))]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(C)]
pub struct Point {
    #[cfg_attr(feature = "serde", serde(rename = "X"))]
    pub x: i32,
    pub y: i32,
}

#[derive(Debug)]
#[non_exhaustive]
pub enum Token<'src> {
    Ident(&'src str),
    Number(f64),
    Str(Cow<'src, str>),
    Punct { ch: char, joint: bool },
    Eof,
}

impl Display for Point {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

pub trait Shape: Display + Send + Sync + 'static {
    const SIDES: usize;
    type Output: Into<f64>;
    fn area(&self) -> Self::Output;
    fn describe(&self) -> String where Self: Sized { format!("{} with {} sides", self, Self::SIDES) }
}

// Macros
macro_rules! hashmap {
    ($($key:expr => $value:expr),* $(,)?) => {{
        let mut map = ::std::collections::HashMap::new();
        $( map.insert($key, $value); )*
        map
    }};
}

#[test]
fn macros() {
    println!("Hello, {}! {:?} {:#x} {:>8.3} {name}", "world", vec![1, 2], 255, 3.14159, name = "n");
    eprintln!(r#"raw in macro: "{}""#, 1);
    let v = vec![0u8; 16];
    let m = hashmap! { "a" => 1, "b" => 2, };
    assert_eq!(m.len(), 2, "map should have {} entries", 2);
    assert!(matches!(Token::Eof, Token::Eof));
    let s = format!("{0}-{0}-{1}", 'a', "b");
    let _ = concat!("a", 1, 'b', 2.5, true);
    let _ = include_str!("data.txt");
    todo!();
}

fn generics() {
    let x: Vec<HashMap<String, Vec<Option<Box<dyn Fn(i32) -> i32 + Send>>>>> = Vec::new();
    let y = Vec::<i32>::with_capacity(10);
    let z = "42".parse::<u64>().unwrap();
    let cmp = 1 < 2 && 3 > 2;
    let shifts = (1u32 << 4) >> 2;
    let closure = |a: i32, b| -> i32 { a + b };
    let r#type = "raw identifier";
    let r#match = 1;
    let ptr = &raw const x;
    let q = Some(5)?;
}

/* final nested /* comment */ closed */ const LAST: char = 'z';
