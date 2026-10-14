//! The small, versioned CBOR boundary uses UTF-16LE byte strings for user text.
//! A bounded reader is used instead of deserializing arbitrary recursive input.
use crate::{Error, Result, MAX_OUTPUT, MAX_STRUCTURE_DEPTH};

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i128),
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<Value>),
    Map(Vec<(Value, Value)>),
}

impl Value {
    pub fn get(&self, name: &str) -> &Value {
        static NULL: Value = Value::Null;
        match self {
            Self::Map(items) => items
                .iter()
                .rev()
                .find_map(|(k, v)| matches!(k, Self::Text(s) if s == name).then_some(v))
                .unwrap_or(&NULL),
            _ => &NULL,
        }
    }
    pub fn int(&self) -> Result<i128> {
        if let Self::Int(n) = self {
            Ok(*n)
        } else {
            Err(Error::request("expected integer"))
        }
    }
    pub fn u64(&self) -> Result<u64> {
        u64::try_from(self.int()?).map_err(|_| Error::request("integer outside uint64"))
    }
    pub fn i64(&self) -> Result<i64> {
        i64::try_from(self.int()?).map_err(|_| Error::request("integer outside int64"))
    }
    pub fn bytes(&self) -> Result<&[u8]> {
        if let Self::Bytes(b) = self {
            Ok(b)
        } else {
            Err(Error::request("expected byte string"))
        }
    }
    pub fn array(&self) -> Result<&[Value]> {
        if let Self::Array(a) = self {
            Ok(a)
        } else {
            Err(Error::request("expected array"))
        }
    }
    pub fn text(&self) -> Result<&str> {
        if let Self::Text(s) = self {
            Ok(s)
        } else {
            Err(Error::request("expected protocol name"))
        }
    }
    pub fn bool(&self) -> Result<bool> {
        if let Self::Bool(b) = self {
            Ok(*b)
        } else {
            Err(Error::request("expected boolean"))
        }
    }
    pub fn units(&self) -> Result<Vec<u16>> {
        from_bytes(self.bytes()?)
    }
}

pub fn map<const N: usize>(entries: [(&str, Value); N]) -> Value {
    Value::Map(
        entries
            .into_iter()
            .map(|(k, v)| (Value::Text(k.into()), v))
            .collect(),
    )
}
pub fn int(n: impl Into<i128>) -> Value {
    Value::Int(n.into())
}
pub fn text(s: &str) -> Value {
    units(&s.encode_utf16().collect::<Vec<_>>())
}
pub fn units(s: &[u16]) -> Value {
    Value::Bytes(s.iter().flat_map(|c| c.to_le_bytes()).collect())
}
pub fn from_bytes(b: &[u8]) -> Result<Vec<u16>> {
    if !b.len().is_multiple_of(2) {
        return Err(Error::request("odd UTF-16 byte length"));
    }
    Ok(b.chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect())
}
pub fn version(v: &Value) -> Result<()> {
    if v.get("v").u64()? == 1 {
        Ok(())
    } else {
        Err(Error::request("unsupported CBOR version"))
    }
}

pub fn decode(bytes: &[u8]) -> Result<Value> {
    let mut reader = Reader {
        bytes,
        pos: 0,
        nodes: 0,
    };
    let value = reader.value(0)?;
    if reader.pos != bytes.len() {
        return Err(Error::request("trailing CBOR input"));
    }
    Ok(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
    nodes: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or_else(|| Error::request("CBOR length overflow"))?;
        let result = self
            .bytes
            .get(self.pos..end)
            .ok_or_else(|| Error::request("truncated CBOR"))?;
        self.pos = end;
        Ok(result)
    }
    fn size(&mut self, info: u8) -> Result<u64> {
        Ok(match info {
            0..=23 => info as u64,
            24 => self.take(1)?[0] as u64,
            25 => u16::from_be_bytes(self.take(2)?.try_into().unwrap()) as u64,
            26 => u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as u64,
            27 => u64::from_be_bytes(self.take(8)?.try_into().unwrap()),
            _ => return Err(Error::request("indefinite CBOR is unsupported")),
        })
    }
    fn value(&mut self, depth: usize) -> Result<Value> {
        self.nodes += 1;
        if depth > MAX_STRUCTURE_DEPTH || self.nodes > 500_000 {
            return Err(Error::limit("CBOR structure limit"));
        }
        let head = self.take(1)?[0];
        let major = head >> 5;
        if major == 7 {
            return match head {
                0xf4 => Ok(Value::Bool(false)),
                0xf5 => Ok(Value::Bool(true)),
                0xf6 => Ok(Value::Null),
                _ => Err(Error::request("unsupported CBOR scalar")),
            };
        }
        let size = self.size(head & 31)?;
        if major == 0 {
            return Ok(Value::Int(size as i128));
        }
        if major == 1 {
            return Ok(Value::Int(-1 - size as i128));
        }
        let n = usize::try_from(size).map_err(|_| Error::limit("CBOR length limit"))?;
        // Every array/map entry requires at least one byte; reject malicious lengths before allocation.
        if n > self.bytes.len().saturating_sub(self.pos) {
            return Err(Error::request("CBOR length exceeds input"));
        }
        match major {
            2 => Ok(Value::Bytes(self.take(n)?.to_vec())),
            3 => Ok(Value::Text(
                std::str::from_utf8(self.take(n)?)
                    .map_err(|_| Error::request("invalid CBOR text"))?
                    .into(),
            )),
            4 => {
                let mut a = Vec::with_capacity(n.min(4096));
                for _ in 0..n {
                    a.push(self.value(depth + 1)?);
                }
                Ok(Value::Array(a))
            }
            5 => {
                let mut m = Vec::with_capacity(n.min(4096));
                for _ in 0..n {
                    m.push((self.value(depth + 1)?, self.value(depth + 1)?));
                }
                Ok(Value::Map(m))
            }
            _ => Err(Error::request("unsupported CBOR type")),
        }
    }
}

pub fn encode(v: &Value) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    write(v, &mut out, 0)?;
    Ok(out)
}
fn head(kind: u8, n: u64, out: &mut Vec<u8>) {
    match n {
        0..=23 => out.push((kind << 5) | n as u8),
        24..=255 => {
            out.push((kind << 5) | 24);
            out.push(n as u8);
        }
        256..=65535 => {
            out.push((kind << 5) | 25);
            out.extend((n as u16).to_be_bytes());
        }
        65536..=4294967295 => {
            out.push((kind << 5) | 26);
            out.extend((n as u32).to_be_bytes());
        }
        _ => {
            out.push((kind << 5) | 27);
            out.extend(n.to_be_bytes());
        }
    }
}
fn write(v: &Value, out: &mut Vec<u8>, depth: usize) -> Result<()> {
    if depth > MAX_STRUCTURE_DEPTH {
        return Err(Error::limit("CBOR output nesting limit"));
    }
    match v {
        Value::Null => out.push(0xf6),
        Value::Bool(b) => out.push(if *b { 0xf5 } else { 0xf4 }),
        Value::Int(n) if *n >= 0 => head(
            0,
            u64::try_from(*n).map_err(|_| Error::request("CBOR integer overflow"))?,
            out,
        ),
        Value::Int(n) => head(
            1,
            u64::try_from(-1 - *n).map_err(|_| Error::request("CBOR integer overflow"))?,
            out,
        ),
        Value::Bytes(b) => {
            head(2, b.len() as u64, out);
            if b.len() > MAX_OUTPUT.saturating_sub(out.len()) {
                return Err(Error::limit("output byte limit"));
            }
            out.extend(b);
        }
        Value::Text(s) => {
            head(3, s.len() as u64, out);
            out.extend(s.as_bytes());
        }
        Value::Array(a) => {
            head(4, a.len() as u64, out);
            for item in a {
                write(item, out, depth + 1)?;
            }
        }
        Value::Map(m) => {
            head(5, m.len() as u64, out);
            for (k, v) in m {
                write(k, out, depth + 1)?;
                write(v, out, depth + 1)?;
            }
        }
    }
    if out.len() > MAX_OUTPUT {
        return Err(Error::limit("output byte limit"));
    }
    Ok(())
}
