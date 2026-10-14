use crate::{Error, Result, MAX_STRUCTURE_DEPTH};

#[derive(Debug)]
pub enum Field<'a> {
    Int(i64),
    String(&'a [u8]),
    Bytes(&'a [u8]),
    Struct(Vec<(u8, Field<'a>)>),
    Other,
}
type Fields<'a> = Vec<(u8, Field<'a>)>;
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    nodes: usize,
}
pub fn parse(data: &[u8]) -> Result<Fields<'_>> {
    Reader {
        data,
        pos: 0,
        nodes: 0,
    }
    .fields(0, false)
}
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or_else(|| Error::malformed("TARS length overflow"))?;
        let b = self
            .data
            .get(self.pos..end)
            .ok_or_else(|| Error::malformed("truncated TARS field"))?;
        self.pos = end;
        Ok(b)
    }
    fn head(&mut self) -> Result<(u8, u8)> {
        let b = self.take(1)?[0];
        let tag = if b >> 4 == 15 {
            self.take(1)?[0]
        } else {
            b >> 4
        };
        Ok((tag, b & 15))
    }
    fn fields(&mut self, depth: usize, end: bool) -> Result<Fields<'a>> {
        let mut result = Vec::new();
        while self.pos < self.data.len() {
            let (tag, kind) = self.head()?;
            if kind == 11 {
                if end {
                    return Ok(result);
                }
                return Err(Error::malformed("unexpected TARS struct end"));
            }
            result.push((tag, self.field(kind, depth)?));
        }
        if end {
            Err(Error::malformed("unterminated TARS struct"))
        } else {
            Ok(result)
        }
    }
    fn count(&mut self) -> Result<usize> {
        let (tag, kind) = self.head()?;
        if tag != 0 {
            return Err(Error::malformed("invalid TARS count tag"));
        }
        let n = self.number(kind)?;
        let n = usize::try_from(n).map_err(|_| Error::malformed("negative TARS count"))?;
        if n > self.data.len() - self.pos {
            return Err(Error::malformed("TARS count exceeds input"));
        }
        Ok(n)
    }
    fn number(&mut self, kind: u8) -> Result<i64> {
        Ok(match kind {
            0 => self.take(1)?[0] as i8 as i64,
            1 => i16::from_be_bytes(self.take(2)?.try_into().unwrap()) as i64,
            2 => i32::from_be_bytes(self.take(4)?.try_into().unwrap()) as i64,
            3 => i64::from_be_bytes(self.take(8)?.try_into().unwrap()),
            12 => 0,
            _ => return Err(Error::malformed("invalid TARS integer type")),
        })
    }
    fn field(&mut self, kind: u8, depth: usize) -> Result<Field<'a>> {
        self.nodes += 1;
        if depth > MAX_STRUCTURE_DEPTH || self.nodes > 500_000 {
            return Err(Error::limit("TARS structure limit"));
        }
        Ok(match kind {
            0..=3 | 12 => Field::Int(self.number(kind)?),
            4 => {
                self.take(4)?;
                Field::Other
            }
            5 => {
                self.take(8)?;
                Field::Other
            }
            6 => {
                let n = self.take(1)?[0] as usize;
                Field::String(self.take(n)?)
            }
            7 => {
                let n = u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as usize;
                Field::String(self.take(n)?)
            }
            8 => {
                let n = self.count()?;
                for _ in 0..n {
                    for _ in 0..2 {
                        let (_, kind) = self.head()?;
                        self.field(kind, depth + 1)?;
                    }
                }
                Field::Other
            }
            9 => {
                let n = self.count()?;
                for _ in 0..n {
                    let (_, kind) = self.head()?;
                    self.field(kind, depth + 1)?;
                }
                Field::Other
            }
            10 => Field::Struct(self.fields(depth + 1, true)?),
            13 => {
                let (_, sub) = self.head()?;
                if sub != 0 {
                    return Err(Error::malformed("invalid TARS simple list"));
                }
                let n = self.count()?;
                Field::Bytes(self.take(n)?)
            }
            _ => return Err(Error::malformed("unknown TARS wire type")),
        })
    }
}
fn get<'a, 'b>(fields: &'b [(u8, Field<'a>)], tag: u8) -> Option<&'b Field<'a>> {
    fields.iter().find(|(t, _)| *t == tag).map(|(_, v)| v)
}
pub fn integer(fields: &[(u8, Field<'_>)], tag: u8) -> Option<i64> {
    match get(fields, tag) {
        Some(Field::Int(n)) => Some(*n),
        _ => None,
    }
}
pub fn bytes<'a>(fields: &[(u8, Field<'a>)], tag: u8) -> Result<&'a [u8]> {
    match get(fields, tag) {
        Some(Field::Bytes(b)) => Ok(b),
        _ => Err(Error::malformed("missing TARS bytes field")),
    }
}
pub fn structure<'a, 'b>(fields: &'b [(u8, Field<'a>)], tag: u8) -> Result<&'b [(u8, Field<'a>)]> {
    match get(fields, tag) {
        Some(Field::Struct(s)) => Ok(s),
        _ => Err(Error::malformed("missing TARS struct field")),
    }
}
pub fn string(fields: &[(u8, Field<'_>)], tag: u8) -> Result<Vec<u16>> {
    match get(fields, tag) {
        Some(Field::String(s)) => Ok(std::str::from_utf8(s)
            .map_err(|_| Error::malformed("invalid TARS UTF-8"))?
            .encode_utf16()
            .collect()),
        None => Ok(Vec::new()),
        _ => Err(Error::malformed("invalid TARS string type")),
    }
}

fn head(out: &mut Vec<u8>, tag: u8, kind: u8) {
    if tag < 15 {
        out.push(tag << 4 | kind)
    } else {
        out.extend([0xf0 | kind, tag]);
    }
}
pub fn write_integer(out: &mut Vec<u8>, tag: u8, n: i64) {
    if n == 0 {
        head(out, tag, 12)
    } else if let Ok(n) = i8::try_from(n) {
        head(out, tag, 0);
        out.push(n as u8)
    } else if let Ok(n) = i16::try_from(n) {
        head(out, tag, 1);
        out.extend(n.to_be_bytes())
    } else if let Ok(n) = i32::try_from(n) {
        head(out, tag, 2);
        out.extend(n.to_be_bytes())
    } else {
        head(out, tag, 3);
        out.extend(n.to_be_bytes())
    }
}
pub fn write_string(out: &mut Vec<u8>, tag: u8, s: &[u8]) {
    if s.len() < 256 {
        head(out, tag, 6);
        out.push(s.len() as u8)
    } else {
        head(out, tag, 7);
        out.extend((s.len() as u32).to_be_bytes());
    }
    out.extend(s);
}
pub fn write_bytes(out: &mut Vec<u8>, tag: u8, b: &[u8]) {
    head(out, tag, 13);
    head(out, 0, 0);
    write_integer(out, 0, b.len() as i64);
    out.extend(b);
}
