//! JSON strings retain escaped UTF-16 surrogates just as Dart jsonDecode does.
//! Rust String / serde_json cannot represent lone surrogates.
use crate::{Error, Result, MAX_STRUCTURE_DEPTH};

#[derive(Debug)]
pub enum Json {
    Null,
    Bool(bool),
    Number(String),
    String(Vec<u16>),
    Array(Vec<Json>),
    Object(Vec<(Vec<u16>, Json)>),
}
impl Json {
    pub fn get(&self, key: &str) -> &Json {
        static NULL: Json = Json::Null;
        if let Json::Object(m) = self {
            m.iter()
                .rev()
                .find_map(|(k, v)| k.iter().copied().eq(key.encode_utf16()).then_some(v))
                .unwrap_or(&NULL)
        } else {
            &NULL
        }
    }
    pub fn at(&self, index: usize) -> &Json {
        static NULL: Json = Json::Null;
        if let Json::Array(a) = self {
            a.get(index).unwrap_or(&NULL)
        } else {
            &NULL
        }
    }
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }
    pub fn string(&self) -> Vec<u16> {
        match self {
            Self::String(s) => s.clone(),
            Self::Number(n) => n.encode_utf16().collect(),
            Self::Bool(true) => "true".encode_utf16().collect(),
            Self::Bool(false) => "false".encode_utf16().collect(),
            _ => "null".encode_utf16().collect(),
        }
    }
    pub fn integer(&self) -> Option<i64> {
        match self {
            Self::Number(n) => n.parse().ok(),
            _ => None,
        }
    }
    pub fn eq(&self, s: &str) -> bool {
        matches!(self,Self::String(v) if v.iter().copied().eq(s.encode_utf16()))
    }
    pub fn contains(&self, s: &str) -> bool {
        if let Self::String(v) = self {
            let p: Vec<_> = s.encode_utf16().collect();
            v.windows(p.len()).any(|w| w == p)
        } else {
            false
        }
    }
}

pub fn parse(input: &[u8], allow_malformed: bool) -> Result<Json> {
    let source = if allow_malformed {
        String::from_utf8_lossy(input)
    } else {
        std::borrow::Cow::Borrowed(
            std::str::from_utf8(input).map_err(|_| Error::malformed("invalid UTF-8"))?,
        )
    };
    let mut p = Parser {
        input: source.as_bytes(),
        pos: 0,
        nodes: 0,
    };
    let v = p.value(0)?;
    p.space();
    if p.pos != p.input.len() {
        return Err(Error::malformed("trailing JSON"));
    }
    Ok(v)
}
struct Parser<'a> {
    input: &'a [u8],
    pos: usize,
    nodes: usize,
}
impl Parser<'_> {
    fn space(&mut self) {
        while self
            .input
            .get(self.pos)
            .is_some_and(|c| matches!(c, b' ' | b'\r' | b'\n' | b'\t'))
        {
            self.pos += 1;
        }
    }
    fn consume(&mut self, b: u8) -> bool {
        if self.input.get(self.pos) == Some(&b) {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn value(&mut self, depth: usize) -> Result<Json> {
        self.nodes += 1;
        if depth > MAX_STRUCTURE_DEPTH || self.nodes > 500_000 {
            return Err(Error::limit("JSON structure limit"));
        }
        self.space();
        match self.input.get(self.pos).copied() {
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b'[') => {
                self.pos += 1;
                self.space();
                let mut a = Vec::new();
                if self.consume(b']') {
                    return Ok(Json::Array(a));
                }
                loop {
                    a.push(self.value(depth + 1)?);
                    self.space();
                    if self.consume(b']') {
                        break;
                    }
                    if !self.consume(b',') {
                        return Err(Error::malformed("invalid JSON array"));
                    }
                }
                Ok(Json::Array(a))
            }
            Some(b'{') => {
                self.pos += 1;
                self.space();
                let mut a = Vec::new();
                if self.consume(b'}') {
                    return Ok(Json::Object(a));
                }
                loop {
                    self.space();
                    let k = self.string()?;
                    self.space();
                    if !self.consume(b':') {
                        return Err(Error::malformed("invalid JSON object"));
                    }
                    a.push((k, self.value(depth + 1)?));
                    self.space();
                    if self.consume(b'}') {
                        break;
                    }
                    if !self.consume(b',') {
                        return Err(Error::malformed("invalid JSON object"));
                    }
                }
                Ok(Json::Object(a))
            }
            Some(b'n') => {
                self.literal(b"null")?;
                Ok(Json::Null)
            }
            Some(b't') => {
                self.literal(b"true")?;
                Ok(Json::Bool(true))
            }
            Some(b'f') => {
                self.literal(b"false")?;
                Ok(Json::Bool(false))
            }
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(Error::malformed("invalid JSON token")),
        }
    }
    fn literal(&mut self, v: &[u8]) -> Result<()> {
        if self.input.get(self.pos..self.pos + v.len()) == Some(v) {
            self.pos += v.len();
            Ok(())
        } else {
            Err(Error::malformed("invalid JSON literal"))
        }
    }
    fn number(&mut self) -> Result<Json> {
        let start = self.pos;
        self.consume(b'-');
        if self.consume(b'0') {
        } else {
            let s = self.pos;
            while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
                self.pos += 1;
            }
            if s == self.pos {
                return Err(Error::malformed("invalid JSON number"));
            }
        }
        if self.consume(b'.') {
            let s = self.pos;
            while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
                self.pos += 1;
            }
            if s == self.pos {
                return Err(Error::malformed("invalid JSON fraction"));
            }
        }
        if self.consume(b'e') || self.consume(b'E') {
            if !self.consume(b'+') {
                self.consume(b'-');
            }
            let s = self.pos;
            while self.input.get(self.pos).is_some_and(u8::is_ascii_digit) {
                self.pos += 1;
            }
            if s == self.pos {
                return Err(Error::malformed("invalid JSON exponent"));
            }
        }
        Ok(Json::Number(
            std::str::from_utf8(&self.input[start..self.pos])
                .unwrap()
                .into(),
        ))
    }
    fn string(&mut self) -> Result<Vec<u16>> {
        if !self.consume(b'"') {
            return Err(Error::malformed("expected JSON string"));
        }
        let mut result = Vec::new();
        let mut start = self.pos;
        loop {
            let c = *self
                .input
                .get(self.pos)
                .ok_or_else(|| Error::malformed("unterminated JSON string"))?;
            if c == b'"' || c == b'\\' {
                let s = std::str::from_utf8(&self.input[start..self.pos])
                    .map_err(|_| Error::malformed("invalid JSON UTF-8"))?;
                result.extend(s.encode_utf16());
                self.pos += 1;
                if c == b'"' {
                    return Ok(result);
                }
                let esc = *self
                    .input
                    .get(self.pos)
                    .ok_or_else(|| Error::malformed("truncated JSON escape"))?;
                self.pos += 1;
                result.push(match esc {
                    b'"' => 34,
                    b'\\' => 92,
                    b'/' => 47,
                    b'b' => 8,
                    b'f' => 12,
                    b'n' => 10,
                    b'r' => 13,
                    b't' => 9,
                    b'u' => {
                        let bytes = self
                            .input
                            .get(self.pos..self.pos + 4)
                            .ok_or_else(|| Error::malformed("truncated Unicode escape"))?;
                        let mut value = 0u16;
                        for b in bytes {
                            value = (value << 4)
                                | (*b as char)
                                    .to_digit(16)
                                    .ok_or_else(|| Error::malformed("invalid Unicode escape"))?
                                    as u16;
                        }
                        self.pos += 4;
                        value
                    }
                    _ => return Err(Error::malformed("invalid JSON escape")),
                });
                start = self.pos;
            } else {
                if c < 32 {
                    return Err(Error::malformed("control character in JSON string"));
                }
                self.pos += 1;
            }
        }
    }
}
