use std::str::FromStr;
use std::{fmt::Display, hash::Hash};

use nom::{
    branch::alt,
    bytes::complete::{tag, take},
    character::complete::digit1,
    error::context,
    multi::{length_count, many_till},
    sequence::{pair, preceded, terminated},
    Finish, IResult, Parser,
};
use num_bigint::{BigInt, Sign};

/// Represent a parsed syrup value.
///
/// Value implements equality, ordering and hashing traits (Eq, Ord, Hash) based
/// on the binary on-the-wire representation. This is used to canonicalize
/// values according to the syrup specification.
#[derive(Debug, Clone)]
pub enum Value {
    Boolean(bool),
    Float(f32),
    Double(f64),
    Integer(BigInt),
    Binary(Vec<u8>),
    String(String),
    Symbol(String),
    Dictionary(Vec<(Self, Self)>),
    Sequence(Vec<Self>),
    Record { label: Box<Self>, fields: Vec<Self> },
    Set(Vec<Self>),
}

impl Value {
    /// Create a syrup boolean value.
    pub fn boolean(b: bool) -> Value {
        Value::Boolean(b)
    }
    /// Create a syrup float value.
    pub fn float(f: f32) -> Value {
        Value::Float(f)
    }
    /// Create a syrup double value.
    pub fn double(d: f64) -> Value {
        Value::Double(d)
    }
    /// Create a syrup integer value.
    pub fn integer<T: Into<BigInt>>(i: T) -> Value {
        Value::Integer(i.into())
    }
    /// Create a syrup binary data value.
    pub fn binary<'a, T: Into<&'a [u8]>>(b: T) -> Value {
        Value::Binary(b.into().to_vec())
    }
    /// Create a syrup utf-8 string value.
    pub fn string<'a, T: Into<&'a str>>(s: T) -> Value {
        Value::String(s.into().to_string())
    }
    /// Create a syrup symbol value.
    pub fn symbol<'a, T: Into<&'a str>>(s: T) -> Value {
        Value::Symbol(s.into().to_string())
    }
    /// Create a canonicalized syrup dictionary value.
    pub fn dictionary(mut d: Vec<(Value, Value)>) -> Value {
        d.sort();
        Value::Dictionary(d)
    }
    /// Create a syrup sequence value.
    pub fn sequence(s: Vec<Value>) -> Value {
        Value::Sequence(s)
    }
    /// Create a syrup record value.
    pub fn record(label: Value, fields: Vec<Value>) -> Value {
        Value::Record {
            label: Box::new(label),
            fields,
        }
    }
    /// Create a canonicalized syrup set value.
    pub fn set(mut s: Vec<Value>) -> Value {
        s.sort();
        Value::Set(s)
    }

    /// Compare one syrup value to another, according to canonicalization rules
    /// for sorting.
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.to_vec().cmp(other.to_vec().as_ref())
    }

    /// Render syrup value to its binary on-the-wire representation.
    pub fn to_vec(&self) -> Vec<u8> {
        match self {
            Value::Boolean(true) => [b't'].to_vec(),
            Value::Boolean(false) => [b'f'].to_vec(),
            Value::Float(f) => [[b'F'].as_slice(), f.to_be_bytes().as_slice()].concat(),
            Value::Double(d) => [[b'D'].as_slice(), d.to_be_bytes().as_slice()].concat(),
            Value::Integer(big_int) => {
                let suffix = if big_int.sign() == Sign::Minus {
                    "-"
                } else {
                    "+"
                };
                format!("{}{}", big_int.magnitude().to_str_radix(10), suffix)
                    .as_bytes()
                    .to_vec()
            }
            Value::Binary(b) => [format!("{}:", b.len()).as_bytes(), b].concat(),
            Value::String(s) => {
                [format!("{}\"", s.as_bytes().len()).as_bytes(), s.as_bytes()].concat()
            }
            Value::Symbol(s) => {
                [format!("{}'", s.as_bytes().len()).as_bytes(), s.as_bytes()].concat()
            }
            Value::Dictionary(d) => [
                [b'{'].as_slice(),
                d.iter()
                    .map(|(k, v)| vec![k.to_vec(), v.to_vec()].concat())
                    .collect::<Vec<Vec<u8>>>()
                    .concat()
                    .as_slice(),
                [b'}'].as_slice(),
            ]
            .concat(),
            Value::Sequence(s) => [
                [b'['].as_slice(),
                s.iter()
                    .map(|v| v.to_vec())
                    .collect::<Vec<Vec<u8>>>()
                    .concat()
                    .as_slice(),
                [b']'].as_slice(),
            ]
            .concat(),
            Value::Record { label, fields } => [
                [b'<'].as_slice(),
                label.to_vec().as_slice(),
                fields
                    .iter()
                    .map(|v| v.to_vec())
                    .collect::<Vec<Vec<u8>>>()
                    .concat()
                    .as_slice(),
                [b'>'].as_slice(),
            ]
            .concat(),
            Value::Set(s) => [
                [b'#'].as_slice(),
                s.iter()
                    .map(|v| v.to_vec())
                    .collect::<Vec<Vec<u8>>>()
                    .concat()
                    .as_slice(),
                [b'$'].as_slice(),
            ]
            .concat(),
        }
    }
}

/// Error during syrup format processing.
#[derive(Debug, PartialEq)]
pub enum Error {
    Message(String),
    Parse(String),
}

impl Error {
    pub(crate) fn message<T: ToString>(s: T) -> Error {
        Error::Message(s.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

impl Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Message(msg) => f.write_str(msg),
            Error::Parse(msg) => f.write_str(msg),
        }
    }
}

impl From<nom::Err<nom::error::Error<&[u8]>>> for Error {
    fn from(value: nom::Err<nom::error::Error<&[u8]>>) -> Self {
        match value {
            nom::Err::Incomplete(_) => Error::Message("incomplete input".to_string()),
            nom::Err::Error(e) => e.into(),
            nom::Err::Failure(e) => e.into(),
        }
    }
}

impl From<nom::error::Error<&[u8]>> for Error {
    fn from(e: nom::error::Error<&[u8]>) -> Self {
        Error::Parse(format!(
            "near {}: {}",
            String::from_utf8_lossy(e.input),
            e.code.description()
        ))
    }
}

impl std::error::Error for Error {}

impl TryFrom<&[u8]> for Value {
    type Error = Error;

    fn try_from(v: &[u8]) -> Result<Self> {
        value(v)
            .finish()
            .map(|(_, res)| res)
            .map_err(|e| Error::Parse(format!("{:?}", e)))
    }
}

impl FromStr for Value {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self> {
        value(s.as_bytes())
            .finish()
            .map(|(_, res)| res)
            .map_err(|e| e.into())
    }
}

pub(crate) fn value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "value",
        alt((
            boolean_value,
            float_value,
            double_value,
            integer_value,
            binary_value,
            string_value,
            symbol_value,
            dictionary_value,
            sequence_value,
            record_value,
            set_value,
        )),
    )(input)
}

fn boolean_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("boolean", alt((tag("t"), tag("f"))))(input).map(|(next_input, res)| {
        (
            next_input,
            match res {
                b"t" => Value::Boolean(true),
                b"f" => Value::Boolean(false),
                _ => unreachable!("parser"),
            },
        )
    })
}

fn float_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("float", preceded(tag("F"), take(4u8)))(input).map(|(next_input, res)| {
        (
            next_input,
            Value::Float(f32::from_be_bytes(res.try_into().unwrap())),
        )
    })
}

fn double_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("double", preceded(tag("D"), take(8u8)))(input).map(|(next_input, res)| {
        (
            next_input,
            Value::Double(f64::from_be_bytes(res.try_into().unwrap())),
        )
    })
}

fn integer_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("integer", pair(digit1, alt((tag("+"), tag("-")))))(input).map(|(next_input, res)| {
        let (num_str, sign_str) = res;
        let sign = match sign_str {
            b"+" => Sign::Plus,
            b"-" => Sign::Minus,
            _ => unreachable!(),
        };
        (
            next_input,
            Value::Integer(
                BigInt::from_radix_be(
                    sign,
                    num_str
                        .iter()
                        .map(|d| d - 0x30)
                        .collect::<Vec<u8>>()
                        .as_slice(),
                    10,
                )
                .unwrap(),
            ),
        )
    })
}

fn binary_value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "binary",
        length_count(
            terminated(digit1, tag(":"))
                .map(|res| u32::from_str(String::from_utf8_lossy(res).as_ref()).unwrap()),
            take(1u8),
        ),
    )(input)
    .map(|(next_input, res)| {
        (
            next_input,
            Value::Binary(res.iter().map(|b| b[0]).collect()),
        )
    })
}

fn string_value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "string",
        length_count(
            terminated(digit1, tag("\""))
                .map(|res| u32::from_str(String::from_utf8_lossy(res).as_ref()).unwrap()),
            take(1u8),
        ),
    )(input)
    .map(|(next_input, res)| {
        (
            next_input,
            Value::String(
                String::from_utf8_lossy(res.iter().map(|b| b[0]).collect::<Vec<u8>>().as_slice())
                    .into_owned(),
            ),
        )
    })
}

fn symbol_value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "symbol",
        length_count(
            terminated(digit1, tag("\'"))
                .map(|res| u32::from_str(String::from_utf8_lossy(res).as_ref()).unwrap()),
            take(1u8),
        ),
    )(input)
    .map(|(next_input, res)| {
        (
            next_input,
            Value::Symbol(
                String::from_utf8_lossy(res.iter().map(|b| b[0]).collect::<Vec<u8>>().as_slice())
                    .into_owned(),
            ),
        )
    })
}

fn sequence_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("sequence", preceded(tag("["), many_till(value, tag("]"))))(input)
        .map(|(next_input, res)| (next_input, Value::Sequence(res.0)))
}

fn dictionary_value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "dictionary",
        preceded(tag("{"), many_till(pair(value, value), tag("}"))),
    )(input)
    .map(|(next_input, mut res)| {
        res.0.sort();
        (next_input, Value::Dictionary(res.0))
    })
}

fn record_value(input: &[u8]) -> IResult<&[u8], Value> {
    context(
        "sequence",
        preceded(tag("<"), pair(value, many_till(value, tag(">")))),
    )(input)
    .map(|(next_input, res)| {
        (
            next_input,
            Value::Record {
                label: Box::new(res.0),
                fields: res.1 .0,
            },
        )
    })
}

fn set_value(input: &[u8]) -> IResult<&[u8], Value> {
    context("sequence", preceded(tag("#"), many_till(value, tag("$"))))(input).map(
        |(next_input, mut res)| {
            res.0.sort();
            (next_input, Value::Set(res.0))
        },
    )
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        return self.cmp(other).is_eq();
    }
}

impl Eq for Value {}

impl Hash for Value {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.to_vec().hash(state);
    }
}

impl PartialOrd for Value {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Value {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.cmp(other)
    }
}

#[cfg(test)]
mod tests {
    use std::{fs::File, io::Read, path::PathBuf};

    use nom::AsBytes;

    use super::*;

    #[test]
    fn try_from_slice() {
        assert_eq!(b"t".as_slice().try_into(), Ok(Value::boolean(true)),);
        assert_eq!(b"f".as_slice().try_into(), Ok(Value::boolean(false)),);
        assert_eq!(
            b"F\x3d\xcc\xcc\xcd".as_slice().try_into(),
            Ok(Value::float(0.1)),
        );
        assert_eq!(
            b"D\x3f\xb9\x99\x99\x99\x99\x99\x9a".as_slice().try_into(),
            Ok(Value::double(0.1)),
        );
    }

    #[test]
    fn invalid() {
        // TODO: improve nom error messages
        assert_eq!(
            Value::from_str("nope"),
            Err::<Value, Error>(Error::Parse("near nope: Tag".to_string()))
        )
    }

    #[test]
    fn from_str() {
        assert_eq!(Value::from_str("t"), Ok(Value::boolean(true)),);
        assert_eq!(Value::from_str("f"), Ok(Value::boolean(false)),);
        assert_eq!(Value::from_str("42+"), Ok(Value::integer(42)),);
        assert_eq!(Value::from_str("42-"), Ok(Value::integer(-42)),);
        assert_eq!(
            Value::from_str("5:hello"),
            Ok(Value::binary(b"hello".as_slice()))
        );
        assert_eq!(Value::from_str("3\"foo"), Ok(Value::string("foo")));
        assert_eq!(Value::from_str("3'foo"), Ok(Value::symbol("foo")));
        assert_eq!(
            Value::from_str("[1+2+3+]"),
            Ok(Value::sequence(vec![
                Value::integer(1),
                Value::integer(2),
                Value::integer(3),
            ]))
        );
        assert_eq!(
            Value::from_str("{3\"goo4\"muck3\"foo3\"bar}"),
            Ok(Value::Dictionary(vec![
                (Value::string("foo"), Value::string("bar")),
                (Value::string("goo"), Value::string("muck"))
            ]))
        );
        assert_eq!(
            Value::from_str("<6:person5:Alice30+t>"),
            Ok(Value::record(
                Value::binary(b"person".as_slice()),
                vec![
                    Value::binary(b"Alice".as_slice()),
                    Value::integer(30),
                    Value::boolean(true),
                ]
            ))
        );
        assert_eq!(
            Value::from_str("#3\"foo3\"bar$"),
            Ok(Value::set(vec![Value::string("bar"), Value::string("foo")]))
        );
    }

    #[test]
    fn round_trip_from_str_to_vec() {
        for s in [
            "t",
            "f",
            "10+",
            "10-",
            "5:hello",
            "3\"foo",
            "4'none",
            "[1+2+3+]",
            "{3\"foo3\"bar3\"goo4\"muck}",
            "<6:person5:Alice30+t>",
            "#3\"bar3\"foo$",
        ] {
            assert_eq!(
                Value::from_str(s).unwrap().to_vec(),
                s.as_bytes().to_vec(),
                "round trip value: {}",
                s
            );
        }
    }

    #[test]
    fn parse_zoo() {
        let zoo_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("zoo.bin");
        let mut zoo_file = File::open(zoo_path).expect("open testdata/zoo.bin");
        let mut buf = vec![];
        zoo_file
            .read_to_end(&mut buf)
            .expect("read testdata/zoo.bin");
        let zoo_actual: Value = buf.as_bytes().try_into().expect("parse zoo.bin");
        let zoo_expected = Value::record(
            Value::binary(b"zoo".as_slice()),
            vec![
                Value::string("The Grand Menagerie"),
                Value::sequence(vec![
                    Value::dictionary(vec![
                        (Value::symbol("species"), Value::binary(b"cat".as_slice())),
                        (Value::symbol("name"), Value::string("Tabatha")),
                        (Value::symbol("age"), Value::integer(12)),
                        (Value::symbol("weight"), Value::double(8.2)),
                        (Value::symbol("alive?"), Value::boolean(true)),
                        (
                            Value::symbol("eats"),
                            Value::set(vec![
                                Value::binary(b"mice".as_slice()),
                                Value::binary(b"fish".as_slice()),
                                Value::binary(b"kibble".as_slice()),
                            ]),
                        ),
                    ]),
                    Value::dictionary(vec![
                        (
                            Value::symbol("species"),
                            Value::binary(b"monkey".as_slice()),
                        ),
                        (Value::symbol("name"), Value::string("George")),
                        (Value::symbol("age"), Value::integer(6)),
                        (Value::symbol("weight"), Value::double(17.24)),
                        (Value::symbol("alive?"), Value::boolean(false)),
                        (
                            Value::symbol("eats"),
                            Value::set(vec![
                                Value::binary(b"bananas".as_slice()),
                                Value::binary(b"insects".as_slice()),
                            ]),
                        ),
                    ]),
                    Value::dictionary(vec![
                        (Value::symbol("species"), Value::binary(b"ghost".as_slice())),
                        (Value::symbol("name"), Value::string("Casper")),
                        (Value::symbol("age"), Value::integer(-12)),
                        (Value::symbol("weight"), Value::double(-34.5)),
                        (Value::symbol("alive?"), Value::boolean(false)),
                        (Value::symbol("eats"), Value::set(vec![])),
                    ]),
                ]),
            ],
        );
        assert_eq!(zoo_expected, zoo_actual);
    }
}
