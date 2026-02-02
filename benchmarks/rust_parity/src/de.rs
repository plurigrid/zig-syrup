use std::{fmt::Display, marker::PhantomData};

use num_bigint::Sign;
use serde::{
    de::{self, MapAccess, SeqAccess, Visitor},
    forward_to_deserialize_any, Deserialize,
};

use crate::format::{value, Error, Result, Value};

impl de::Error for Error {
    fn custom<T: Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}

pub struct Deserializer<'de> {
    input: &'de [u8],
    pending: Vec<Value>,
}

impl<'de> Deserializer<'de> {
    pub fn from_bytes(input: &'de [u8]) -> Self {
        Deserializer {
            input,
            pending: vec![],
        }
    }

    fn visit_value<V>(&mut self, visitor: V, value: Value) -> Result<V::Value>
    where
        V: Visitor<'de>,
    {
        match value {
            Value::Boolean(v) => visitor.visit_bool(v),
            Value::Float(v) => visitor.visit_f32(v),
            Value::Double(v) => visitor.visit_f64(v),
            Value::Integer(v) => {
                if v.sign() == Sign::Minus {
                    visitor.visit_i64(i64::try_from(v).map_err(Error::message)?)
                } else {
                    visitor.visit_u64(u64::try_from(v).map_err(Error::message)?)
                }
            }
            Value::Binary(mut v) => {
                v.reverse();
                visitor.visit_seq(BinaryDeserializer::new(v))
            }
            Value::String(v) => visitor.visit_string(v),
            Value::Symbol(v) => {
                if v == "nil" {
                    visitor.visit_unit()
                } else {
                    visitor.visit_string(v)
                }
            }
            Value::Dictionary(mut v) => {
                v.reverse();
                visitor.visit_map(DictionaryAccessor::new(self, v))
            }
            Value::Sequence(mut v) => {
                v.reverse();
                visitor.visit_seq(SequenceAccessor::new(self, v))
            }
            Value::Record {
                label: _,
                mut fields,
            } => {
                if fields.is_empty() {
                    // Empty fields are either a "nil" unit or a unit struct
                    return visitor.visit_unit();
                }
                if let &Value::Symbol(ref _variant) = &fields[0] {
                    // Leading symbol indicates an enum variant.
                    // See Serializer::serialize_*_variant methods.
                    todo!()
                } else if fields.len() == 1 {
                    // A single value is likely some kind of struct (newtype or otherwise).
                    // Just unwrap it.
                    self.visit_value(visitor, fields.pop().unwrap())
                } else {
                    self.pending.push(Value::Sequence(fields));
                    visitor.visit_newtype_struct(self)
                }
            }
            Value::Set(mut v) => {
                v.reverse();
                visitor.visit_seq(SequenceAccessor::new(self, v))
            }
        }
    }
}

/// Deserialize a rust value from a byte-slice containing syrup-formatted data.
pub fn try_from_bytes<'a, T>(b: &'a [u8]) -> Result<T>
where
    T: Deserialize<'a>,
{
    let mut deserializer = Deserializer::from_bytes(b);
    let t = T::deserialize(&mut deserializer)?;
    if deserializer.input.is_empty() {
        Ok(t)
    } else {
        Err(Error::Message("trailing values".to_string()))
    }
}

/// Deserialize a rust value from a parsed representation of syrup-formatted data.
pub fn from_value<'a, T>(v: Value) -> Result<T>
where
    T: Deserialize<'a>,
{
    let mut deserializer = Deserializer::from_bytes(&[]);
    deserializer.pending.push(v);
    let t = T::deserialize(&mut deserializer)?;
    if deserializer.input.is_empty() {
        Ok(t)
    } else {
        Err(Error::Message("trailing values".to_string()))
    }
}

impl<'de, 'a> de::Deserializer<'de> for &'a mut Deserializer<'de> {
    type Error = Error;

    fn deserialize_any<V>(self, visitor: V) -> Result<V::Value>
    where
        V: Visitor<'de>,
    {
        match self.pending.pop() {
            Some(next) => self.visit_value(visitor, next),
            None => {
                let (remaining, parsed) = value(self.input)?;
                self.input = remaining;
                self.visit_value(visitor, parsed)
            }
        }
    }

    forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string
        bytes byte_buf option unit unit_struct newtype_struct seq tuple
        tuple_struct map struct enum identifier ignored_any
    }
}

pub struct BinaryDeserializer<'de> {
    input: Vec<u8>,
    _phantom: Option<&'de PhantomData<()>>,
}

impl<'de> BinaryDeserializer<'de> {
    fn new(input: Vec<u8>) -> BinaryDeserializer<'de> {
        BinaryDeserializer {
            input,
            _phantom: None,
        }
    }
}

impl<'de, 'a> de::Deserializer<'de> for &'a mut BinaryDeserializer<'de> {
    type Error = Error;

    fn deserialize_any<V>(self, _visitor: V) -> Result<V::Value>
    where
        V: Visitor<'de>,
    {
        Err(Error::message("invalid input"))
    }

    forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u16 u32 u64 u128 f32 f64 char str string
        bytes byte_buf option unit unit_struct newtype_struct seq tuple
        tuple_struct map struct enum identifier ignored_any
    }

    fn deserialize_u8<V>(self, visitor: V) -> std::result::Result<V::Value, Self::Error>
    where
        V: Visitor<'de>,
    {
        visitor.visit_u8(self.input.pop().ok_or(Error::message("empty input"))?)
    }
}

impl<'de, 'a> SeqAccess<'de> for BinaryDeserializer<'de> {
    type Error = Error;

    fn next_element_seed<T>(
        &mut self,
        seed: T,
    ) -> std::result::Result<Option<T::Value>, Self::Error>
    where
        T: de::DeserializeSeed<'de>,
    {
        if self.input.is_empty() {
            return Ok(None);
        }
        seed.deserialize(&mut *self).map(Some)
    }
}

struct SequenceAccessor<'a, 'de: 'a> {
    de: &'a mut Deserializer<'de>,
    items: Vec<Value>,
}

impl<'a, 'de> SequenceAccessor<'a, 'de> {
    fn new(de: &'a mut Deserializer<'de>, items: Vec<Value>) -> Self {
        SequenceAccessor { de, items }
    }
}

impl<'de, 'a> SeqAccess<'de> for SequenceAccessor<'a, 'de> {
    type Error = Error;

    fn next_element_seed<T>(
        &mut self,
        seed: T,
    ) -> std::result::Result<Option<T::Value>, Self::Error>
    where
        T: de::DeserializeSeed<'de>,
    {
        match self.items.pop() {
            None => return Ok(None),
            Some(next) => {
                self.de.pending.push(next);
                seed.deserialize(&mut *self.de).map(Some)
            }
        }
    }
}

struct DictionaryAccessor<'a, 'de: 'a> {
    de: &'a mut Deserializer<'de>,
    items: Vec<(Value, Value)>,
}

impl<'a, 'de> DictionaryAccessor<'a, 'de> {
    fn new(de: &'a mut Deserializer<'de>, items: Vec<(Value, Value)>) -> Self {
        DictionaryAccessor { de, items }
    }
}

impl<'de, 'a> MapAccess<'de> for DictionaryAccessor<'a, 'de> {
    type Error = Error;

    fn next_key_seed<K>(&mut self, seed: K) -> std::result::Result<Option<K::Value>, Self::Error>
    where
        K: de::DeserializeSeed<'de>,
    {
        match self.items.last() {
            None => Ok(None),
            Some(next) => {
                self.de.pending.push(next.0.clone());
                seed.deserialize(&mut *self.de).map(Some)
            }
        }
    }

    fn next_value_seed<V>(&mut self, seed: V) -> std::result::Result<V::Value, Self::Error>
    where
        V: de::DeserializeSeed<'de>,
    {
        match self.items.pop() {
            None => Err(Error::message("missing expected dictionary entry value")),
            Some(next) => {
                self.de.pending.push(next.1);
                seed.deserialize(&mut *self.de)
            }
        }
    }
}

#[test]
fn test_simple_types() {
    assert_eq!(Ok(true), try_from_bytes::<bool>(br#"t"#.as_slice()));
    assert_eq!(
        Ok("foo".as_bytes().to_vec()),
        try_from_bytes::<Vec<u8>>(br#"3:foo"#.as_slice())
    );
    assert_eq!(
        Ok("foo".to_string()),
        try_from_bytes::<String>(br#"3"foo"#.as_slice())
    );
    assert_eq!(
        Ok("foo".to_string()),
        try_from_bytes::<String>(br#"3'foo"#.as_slice())
    );
    assert_eq!(
        Ok(vec![1, 2, 3]),
        try_from_bytes::<Vec<u64>>(br#"[1+2+3+]"#.as_slice())
    );
    assert_eq!(
        Ok(vec![1, 2, 3]),
        try_from_bytes::<Vec<u64>>(br#"#1+2+3+$"#.as_slice())
    );
    assert_eq!(
        Ok(vec![vec![1, 2, 3], vec![4, 5, 6]]),
        try_from_bytes::<Vec<Vec<u64>>>(br#"[[1+2+3+][4+5+6+]]"#.as_slice())
    );
}

#[test]
fn test_from_value() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct Test {
        int: u32,
        seq: Vec<String>,
    }

    assert_eq!(
        Ok(Test {
            int: 42,
            seq: vec!["foo".to_owned(), "bar".to_owned()]
        }),
        from_value::<Test>(Value::Record {
            label: Box::new(Value::Symbol("Test".to_owned())),
            fields: vec![Value::Dictionary(vec![
                (Value::Symbol("int".to_owned()), Value::Integer(42.into())),
                (
                    Value::Symbol("seq".to_owned()),
                    Value::Sequence(vec![
                        Value::String("foo".to_owned()),
                        Value::String("bar".to_owned())
                    ])
                )
            ])]
        })
    );
}

#[test]
fn test_struct_from_dictionary() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct Test {
        int: u32,
        seq: Vec<String>,
    }

    assert_eq!(
        Ok(Test {
            int: 42,
            seq: vec!["foo".to_string(), "bar".to_string()]
        }),
        try_from_bytes::<Test>(br#"{3'int42+3'seq[3"foo3"bar]}"#.as_slice())
    );
}

#[test]
fn test_struct_from_record() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct Test {
        int: u32,
        seq: Vec<String>,
    }

    assert_eq!(
        Ok(Test {
            int: 42,
            seq: vec!["foo".to_string(), "bar".to_string()]
        }),
        try_from_bytes::<Test>(br#"<4'Test{3'int42+3'seq[3"foo3"bar]}>"#.as_slice())
    );

    // Note that the record label is discarded; the label isn't actually matched or used here.
    assert_eq!(
        Ok(Test {
            int: 42,
            seq: vec!["foo".to_string(), "bar".to_string()]
        }),
        try_from_bytes::<Test>(br#"<5'Other{3'int42+3'seq[3"foo3"bar]}>"#.as_slice())
    );
}

#[test]
fn test_newtype_struct_from_record() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct Test((String, i32));

    assert_eq!(
        Ok(Test(("foo".to_owned(), -42))),
        try_from_bytes::<Test>(br#"<4'Test3"foo42->"#.as_slice()),
    );
}
