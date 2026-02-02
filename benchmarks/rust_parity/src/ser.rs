use std::fmt::Display;

use serde::{ser, Serialize};

use crate::format::{Error, Result, Value};

impl ser::Error for Error {
    fn custom<T: Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}

pub struct Serializer {
    output: Vec<u8>,
}

/// Serialize a rust value to a syrup-formatted representation.
pub fn to_vec<T>(value: &T) -> Result<Vec<u8>>
where
    T: Serialize,
{
    let mut serializer = Serializer { output: vec![] };
    value.serialize(&mut serializer)?;
    Ok(serializer.output)
}

impl<'a> ser::Serializer for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    type SerializeSeq = Self;

    type SerializeTuple = Self;

    type SerializeTupleStruct = Self;

    type SerializeTupleVariant = Self;

    type SerializeMap = Self;

    type SerializeStruct = Self;

    type SerializeStructVariant = Self;

    fn serialize_bool(self, v: bool) -> Result<Self::Ok> {
        self.output.extend(Value::boolean(v).to_vec());
        Ok(())
    }

    fn serialize_i8(self, v: i8) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_i16(self, v: i16) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_i32(self, v: i32) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_i64(self, v: i64) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_u8(self, v: u8) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_u16(self, v: u16) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_u32(self, v: u32) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_u64(self, v: u64) -> Result<Self::Ok> {
        self.output.extend(Value::integer(v).to_vec());
        Ok(())
    }

    fn serialize_f32(self, v: f32) -> Result<Self::Ok> {
        self.output.extend(Value::float(v).to_vec());
        Ok(())
    }

    fn serialize_f64(self, v: f64) -> Result<Self::Ok> {
        self.output.extend(Value::double(v).to_vec());
        Ok(())
    }

    fn serialize_char(self, v: char) -> Result<Self::Ok> {
        self.output.extend(Value::String(v.to_string()).to_vec());
        Ok(())
    }

    fn serialize_str(self, v: &str) -> Result<Self::Ok> {
        self.output.extend(Value::string(v).to_vec());
        Ok(())
    }

    fn serialize_bytes(self, v: &[u8]) -> Result<Self::Ok> {
        self.output.extend(Value::binary(v).to_vec());
        Ok(())
    }

    fn serialize_none(self) -> Result<Self::Ok> {
        self.serialize_unit()
    }

    fn serialize_some<T>(self, value: &T) -> Result<Self::Ok>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(self)
    }

    fn serialize_unit(self) -> Result<Self::Ok> {
        self.output.extend(Value::symbol("nil").to_vec());
        Ok(())
    }

    fn serialize_unit_struct(self, name: &'static str) -> Result<Self::Ok> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(b">");
        Ok(())
    }

    fn serialize_unit_variant(
        self,
        name: &'static str,
        _variant_index: u32,
        variant: &'static str,
    ) -> Result<Self::Ok> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(Value::symbol(variant).to_vec());
        self.output.extend(b">");
        Ok(())
    }

    fn serialize_newtype_struct<T>(self, name: &'static str, value: &T) -> Result<Self::Ok>
    where
        T: ?Sized + Serialize,
    {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        value.serialize(&mut *self)?;
        self.output.extend(b">");
        Ok(())
    }

    fn serialize_newtype_variant<T>(
        self,
        name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<Self::Ok>
    where
        T: ?Sized + Serialize,
    {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(Value::symbol(variant).to_vec());
        value.serialize(&mut *self)?;
        self.output.extend(b">");
        Ok(())
    }

    fn serialize_seq(self, _len: Option<usize>) -> Result<Self::SerializeSeq> {
        self.output.extend(b"[");
        Ok(self)
    }

    fn serialize_tuple(self, len: usize) -> Result<Self::SerializeTuple> {
        self.serialize_seq(Some(len))
    }

    fn serialize_tuple_struct(
        self,
        name: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeTupleStruct> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        Ok(self)
    }

    fn serialize_tuple_variant(
        self,
        name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeTupleVariant> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(Value::symbol(variant).to_vec());
        Ok(self)
    }

    fn serialize_map(
        self,
        _len: Option<usize>,
    ) -> std::result::Result<Self::SerializeMap, Self::Error> {
        self.output.extend(b"{");
        Ok(self)
    }

    fn serialize_struct(
        self,
        name: &'static str,
        _len: usize,
    ) -> std::result::Result<Self::SerializeStruct, Self::Error> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(b"{");
        Ok(self)
    }

    fn serialize_struct_variant(
        self,
        name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        _len: usize,
    ) -> std::result::Result<Self::SerializeStructVariant, Self::Error> {
        self.output.extend(b"<");
        self.output.extend(Value::symbol(name).to_vec());
        self.output.extend(Value::symbol(variant).to_vec());
        self.output.extend(b"{");
        Ok(self)
    }
}

impl<'a> ser::SerializeSeq for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_element<T>(&mut self, value: &T) -> Result<Self::Ok>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<Self::Ok> {
        self.output.extend(b"]");
        Ok(())
    }
}

impl<'a> ser::SerializeTuple for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_element<T>(&mut self, value: &T) -> Result<Self::Ok>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(&mut **self)
    }

    fn end(self) -> Result<Self::Ok> {
        self.output.extend(b"]");
        Ok(())
    }
}

impl<'a> ser::SerializeTupleStruct for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_field<T>(&mut self, value: &T) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(&mut **self)
    }

    fn end(self) -> std::result::Result<Self::Ok, Self::Error> {
        self.output.extend(b">");
        Ok(())
    }
}

impl<'a> ser::SerializeTupleVariant for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_field<T>(&mut self, value: &T) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(&mut **self)
    }

    fn end(self) -> std::result::Result<Self::Ok, Self::Error> {
        self.output.extend(b">");
        Ok(())
    }
}

impl<'a> ser::SerializeMap for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_key<T>(&mut self, key: &T) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        key.serialize(&mut **self)
    }

    fn serialize_value<T>(&mut self, value: &T) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        value.serialize(&mut **self)
    }

    fn end(self) -> std::result::Result<Self::Ok, Self::Error> {
        self.output.extend(b"}");
        Ok(())
    }
}

impl<'a> ser::SerializeStruct for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_field<T>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        self.output.extend(Value::symbol(key).to_vec());
        value.serialize(&mut **self)
    }

    fn end(self) -> std::result::Result<Self::Ok, Self::Error> {
        self.output.extend(b"}>");
        Ok(())
    }
}

impl<'a> ser::SerializeStructVariant for &'a mut Serializer {
    type Ok = ();

    type Error = Error;

    fn serialize_field<T>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> std::result::Result<(), Self::Error>
    where
        T: ?Sized + Serialize,
    {
        self.output.extend(Value::symbol(key).to_vec());
        value.serialize(&mut **self)
    }

    fn end(self) -> std::result::Result<Self::Ok, Self::Error> {
        self.output.extend(b"}>");
        Ok(())
    }
}

#[test]
fn test_struct() {
    #[derive(Serialize)]
    struct Test {
        int: u32,
        seq: Vec<&'static str>,
    }

    let test = Test {
        int: 1,
        seq: vec!["a", "b"],
    };
    let expected = br#"<4'Test{3'int1+3'seq[1"a1"b]}>"#.to_vec();
    assert_eq!(to_vec(&test).unwrap(), expected);
    assert!(matches!(crate::format::value(expected.as_slice()), Ok(_)));
}

#[test]
fn test_enum() {
    #[derive(Serialize)]
    enum E {
        Unit,
        Newtype(u32),
        Tuple(u32, u32),
        Struct { a: u32 },
    }

    let u = E::Unit;
    let expected = br#"<1'E4'Unit>"#.to_vec();
    assert_eq!(to_vec(&u).unwrap(), expected,);
    assert!(matches!(crate::format::value(expected.as_slice()), Ok(_)));

    let n = E::Newtype(1);
    let expected = br#"<1'E7'Newtype1+>"#.to_vec();
    assert_eq!(to_vec(&n).unwrap(), expected);
    assert!(matches!(crate::format::value(expected.as_slice()), Ok(_)));

    let t = E::Tuple(1, 2);
    let expected = br#"<1'E5'Tuple1+2+>"#.to_vec();
    assert_eq!(to_vec(&t).unwrap(), expected);
    assert!(matches!(crate::format::value(expected.as_slice()), Ok(_)));

    let s = E::Struct { a: 1 };
    let expected = br#"<1'E6'Struct{1'a1+}>"#.to_vec();
    assert_eq!(to_vec(&s).unwrap(), expected);
    assert!(matches!(crate::format::value(expected.as_slice()), Ok(_)));
}
