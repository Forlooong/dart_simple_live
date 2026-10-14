//! Validate framing before Prost, including bounded nesting of legacy groups.
//! Length-delimited embedded messages are validated separately at schema edges.
use crate::{Error, Result, MAX_STRUCTURE_DEPTH};

pub fn validate(data: &[u8]) -> Result<()> {
    let mut reader = Reader {
        data,
        pos: 0,
        fields: 0,
    };
    reader.fields(0, None)
}
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    fields: usize,
}
impl Reader<'_> {
    fn varint(&mut self) -> Result<u64> {
        let mut result = 0;
        for shift in (0..70).step_by(7) {
            let byte = *self
                .data
                .get(self.pos)
                .ok_or_else(|| Error::malformed("truncated protobuf varint"))?;
            self.pos += 1;
            if shift == 63 && byte > 1 {
                return Err(Error::malformed("protobuf varint overflow"));
            }
            result |= ((byte & 127) as u64) << shift;
            if byte & 128 == 0 {
                return Ok(result);
            }
        }
        Err(Error::malformed("protobuf varint overflow"))
    }
    fn skip(&mut self, n: usize) -> Result<()> {
        self.pos = self
            .pos
            .checked_add(n)
            .filter(|n| *n <= self.data.len())
            .ok_or_else(|| Error::malformed("truncated protobuf field"))?;
        Ok(())
    }
    fn fields(&mut self, depth: usize, group: Option<u64>) -> Result<()> {
        if depth > MAX_STRUCTURE_DEPTH {
            return Err(Error::limit("protobuf structure limit"));
        }
        while self.pos < self.data.len() {
            self.fields += 1;
            if self.fields > 500_000 {
                return Err(Error::limit("protobuf field limit"));
            }
            let key = self.varint()?;
            let tag = key >> 3;
            if tag == 0 || tag > 0x1fff_ffff {
                return Err(Error::malformed("invalid protobuf tag"));
            }
            match key & 7 {
                0 => {
                    self.varint()?;
                }
                1 => self.skip(8)?,
                2 => {
                    let n = usize::try_from(self.varint()?)
                        .map_err(|_| Error::malformed("protobuf length overflow"))?;
                    self.skip(n)?;
                }
                3 => self.fields(depth + 1, Some(tag))?,
                4 => {
                    if group == Some(tag) {
                        return Ok(());
                    }
                    return Err(Error::malformed("unmatched protobuf end group"));
                }
                5 => self.skip(4)?,
                _ => return Err(Error::malformed("invalid protobuf wire type")),
            }
        }
        if group.is_some() {
            Err(Error::malformed("unterminated protobuf group"))
        } else {
            Ok(())
        }
    }
}
