use crate::{
    json, tars,
    wire::{self, Value},
    Error, Result, MAX_DECOMPRESSED, MAX_OUTPUT,
};
use prost::Message;
use std::io::Read;

#[derive(Default)]
pub struct Batch {
    pub events: Vec<Value>,
    pub acks: Vec<Value>,
    pub diagnostics: Vec<Value>,
    pub fatal: bool,
    decompressed: usize,
    output_size: usize,
}
impl Batch {
    pub fn diagnostic(&mut self, msg: impl Into<String>) {
        if self.diagnostics.len() < 128 {
            self.diagnostics.push(Value::Text(msg.into()));
        }
    }
    fn event(&mut self, event: Value) -> Result<()> {
        self.output_size = self
            .output_size
            .checked_add(wire::encode(&event)?.len())
            .ok_or_else(|| Error::limit("event output overflow"))?;
        if self.output_size > MAX_OUTPUT - 4096 {
            return Err(Error::limit("event output limit"));
        }
        self.events.push(event);
        Ok(())
    }
    pub fn value(self) -> Value {
        wire::map([
            ("v", wire::int(1)),
            ("events", Value::Array(self.events)),
            ("acks", Value::Array(self.acks)),
            ("diagnostics", Value::Array(self.diagnostics)),
            ("fatal", Value::Bool(self.fatal)),
        ])
    }
    fn inflate(&mut self, source: impl Read) -> Result<Vec<u8>> {
        let left = MAX_DECOMPRESSED.saturating_sub(self.decompressed);
        let mut data = Vec::new();
        source
            .take(left as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|_| Error::malformed("invalid compressed payload"))?;
        if data.len() > left {
            return Err(Error::limit("decompressed byte limit"));
        }
        self.decompressed += data.len();
        Ok(data)
    }
}

fn chat(user: &[u16], text: &[u16], color: u32) -> Value {
    wire::map([
        ("type", wire::int(0)),
        ("user", wire::units(user)),
        ("text", wire::units(text)),
        ("color", wire::int(color)),
    ])
}
fn online(n: i64) -> Value {
    wire::map([("type", wire::int(2)), ("online", wire::int(n))])
}
fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}
fn legacy_color(value: i64) -> u32 {
    if value <= 0 {
        return 0xffffff;
    }
    let len = format!("{value:x}").len();
    if matches!(len, 4 | 6 | 8) {
        value as u32 & 0xffffff
    } else {
        0xffffff
    }
}
pub fn decode(protocol: u32, input: &[u8], out: &mut Batch) -> Result<()> {
    match protocol {
        1 => bilibili(input, out, 0),
        2 => douyu(input, out),
        3 => huya(input, out),
        4 => douyin(input, out),
        _ => Err(Error::request("unknown protocol")),
    }
}

fn bilibili(input: &[u8], out: &mut Batch, depth: usize) -> Result<()> {
    if depth > 4 {
        return Err(Error::limit("compressed nesting limit"));
    }
    let mut offset = 0;
    while offset < input.len() {
        let data = &input[offset..];
        if data.len() < 16 {
            return Err(Error::malformed("truncated Bilibili header"));
        }
        let size = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
        let header = u16::from_be_bytes(data[4..6].try_into().unwrap()) as usize;
        if header < 16 || size < header || size > data.len() {
            return Err(Error::malformed("invalid Bilibili packet length"));
        }
        let version = u16::from_be_bytes(data[6..8].try_into().unwrap());
        let operation = u32::from_be_bytes(data[8..12].try_into().unwrap());
        let body = &data[header..size];
        offset += size;
        match operation {
            3 => {
                if body.len() < 4 {
                    out.diagnostic("truncated Bilibili online count");
                } else {
                    out.event(online(
                        u32::from_be_bytes(body[..4].try_into().unwrap()) as i64
                    ))?;
                }
            }
            5 => match version {
                2 | 3 => {
                    if depth == 4 {
                        return Err(Error::limit("compressed nesting limit"));
                    }
                    let inflated = if version == 2 {
                        out.inflate(flate2::read::ZlibDecoder::new(body))?
                    } else {
                        out.inflate(brotli::Decompressor::new(body, 4096))?
                    };
                    bilibili(&inflated, out, depth + 1)?;
                }
                0 | 1 => {
                    if let Err(e) = bili_json(body, out) {
                        if e.code == 2 {
                            return Err(e);
                        }
                        out.diagnostic(e.message);
                    }
                }
                _ => out.diagnostic("unknown Bilibili protocol version"),
            },
            _ => {}
        }
    }
    Ok(())
}
fn bili_json(input: &[u8], out: &mut Batch) -> Result<()> {
    let object = json::parse(input, true)?;
    let command = object.get("cmd");
    if command.contains("DANMU_MSG") {
        let info = object.get("info");
        let text = info.at(1);
        let name = info.at(2).at(1);
        if text.is_null() || name.is_null() {
            return Err(Error::malformed("missing Bilibili chat fields"));
        }
        out.event(chat(
            &name.string(),
            &text.string(),
            legacy_color(info.at(0).at(3).integer().unwrap_or(0)),
        ))?;
    } else if command.eq("SUPER_CHAT_MESSAGE") {
        let data = object.get("data");
        if data.is_null() {
            return Ok(());
        }
        let user = data.get("user_info");
        let mut face = user.get("face").string();
        face.extend("@200w.jpg".encode_utf16());
        let epoch = |key: &str| -> Result<i64> {
            data.get(key)
                .integer()
                .ok_or_else(|| Error::malformed("invalid super chat timestamp"))?
                .checked_mul(1000)
                // Dart DateTime supports +/-100 million days from the epoch.
                .filter(|value| (-8_640_000_000_000_000..=8_640_000_000_000_000).contains(value))
                .ok_or_else(|| Error::malformed("super chat timestamp overflow"))
        };
        let sc = wire::map([
            ("user", wire::units(&user.get("uname").string())),
            ("face", wire::units(&face)),
            ("text", wire::units(&data.get("message").string())),
            (
                "price",
                wire::int(
                    data.get("price")
                        .integer()
                        .ok_or_else(|| Error::malformed("invalid super chat price"))?,
                ),
            ),
            ("start", wire::int(epoch("start_time")?)),
            ("end", wire::int(epoch("end_time")?)),
            (
                "background",
                wire::units(&data.get("background_color").string()),
            ),
            (
                "bottom",
                wire::units(&data.get("background_bottom_color").string()),
            ),
        ]);
        out.event(wire::map([
            ("type", wire::int(3)),
            ("user", wire::text("SUPER_CHAT_MESSAGE")),
            ("text", wire::text("SUPER_CHAT_MESSAGE")),
            ("color", wire::int(0xffffff)),
            ("sc", sc),
        ]))?;
    }
    Ok(())
}

fn douyu(input: &[u8], out: &mut Batch) -> Result<()> {
    let mut offset = 0;
    while offset < input.len() {
        let data = &input[offset..];
        if data.len() < 12 {
            return Err(Error::malformed("truncated Douyu header"));
        }
        let length = u32::from_le_bytes(data[..4].try_into().unwrap()) as usize;
        let duplicate = u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize;
        let total = length
            .checked_add(4)
            .ok_or_else(|| Error::malformed("Douyu packet length overflow"))?;
        if length < 9 || duplicate != length || total > data.len() {
            return Err(Error::malformed("invalid Douyu packet length"));
        }
        let packet = &data[..total];
        offset += total;
        if packet[total - 1] != 0 {
            out.diagnostic("missing Douyu packet terminator");
            continue;
        }
        if let Err(e) = douyu_text(&packet[12..total - 1], out) {
            if e.code == 2 {
                return Err(e);
            }
            out.diagnostic(e.message);
        }
    }
    Ok(())
}
fn douyu_text(body: &[u8], out: &mut Batch) -> Result<()> {
    let text = std::str::from_utf8(body).map_err(|_| Error::malformed("invalid Douyu UTF-8"))?;
    let mut fields = std::collections::HashMap::new();
    for field in text.split('/').filter(|v| !v.is_empty()) {
        let Some((key, value)) = field.split_once("@=") else {
            continue;
        };
        fields.insert(key, stt_unescape(value));
    }
    if fields.get("type").map(String::as_str) != Some("chatmsg") || !fields.contains_key("dms") {
        return Ok(());
    }
    let col = fields
        .get("col")
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(0);
    let color = match col {
        1 => 0xff0000,
        2 => 0x1e87f0,
        3 => 0x7ac84b,
        4 => 0xff7f00,
        5 => 0x9b39f4,
        6 => 0xff69b4,
        _ => 0xffffff,
    };
    out.event(chat(
        &utf16(fields.get("nn").map(String::as_str).unwrap_or("null")),
        &utf16(fields.get("txt").map(String::as_str).unwrap_or("null")),
        color,
    ))
}
fn stt_unescape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '@' {
            match chars.peek() {
                Some('S') => {
                    chars.next();
                    out.push('/');
                }
                Some('A') => {
                    chars.next();
                    out.push('@');
                }
                _ => out.push(c),
            }
        } else {
            out.push(c)
        }
    }
    out
}

fn huya(input: &[u8], out: &mut Batch) -> Result<()> {
    let command = tars::parse(input)?;
    if tars::integer(&command, 0).unwrap_or(0) != 7 {
        return Ok(());
    }
    let push = tars::parse(tars::bytes(&command, 1)?)?;
    let uri = tars::integer(&push, 1).unwrap_or(0);
    if !matches!(uri, 1400 | 8006) {
        return Ok(());
    }
    let payload = tars::bytes(&push, 2)?;
    if let Err(error) = huya_message(uri, payload, out) {
        if error.code == 2 {
            return Err(error);
        }
        // The outer byte-string provides a trustworthy message boundary.
        out.diagnostic(error.message);
    }
    Ok(())
}

fn huya_message(uri: i64, payload: &[u8], out: &mut Batch) -> Result<()> {
    let fields = tars::parse(payload)?;
    match uri {
        1400 => {
            let sender = tars::structure(&fields, 0)?;
            let format = tars::structure(&fields, 6).unwrap_or(&[]);
            let name = tars::string(sender, 2)?;
            let text = tars::string(&fields, 3)?;
            let color = legacy_color(tars::integer(format, 0).unwrap_or(0));
            out.event(chat(&name, &text, color))?;
        }
        8006 => {
            out.event(online(tars::integer(&fields, 0).unwrap_or(0)))?;
        }
        _ => {}
    }
    Ok(())
}

// This minimal schema keeps wire-compatible tags from the repository's douyin.proto.
// Text uses bytes here so malformed text can be isolated to its individual message.
#[derive(Clone, PartialEq, Message)]
pub struct PushFrame {
    #[prost(uint64, tag = "1")]
    pub seq_id: u64,
    #[prost(uint64, tag = "2")]
    pub log_id: u64,
    #[prost(uint64, tag = "3")]
    pub service: u64,
    #[prost(uint64, tag = "4")]
    pub method: u64,
    #[prost(bytes = "vec", tag = "6")]
    pub payload_encoding: Vec<u8>,
    #[prost(bytes = "vec", tag = "7")]
    pub payload_type: Vec<u8>,
    #[prost(bytes = "vec", tag = "8")]
    pub payload: Vec<u8>,
}
#[derive(Clone, PartialEq, Message)]
pub struct Response {
    #[prost(bytes = "vec", repeated, tag = "1")]
    pub messages: Vec<Vec<u8>>,
    #[prost(bytes = "vec", tag = "5")]
    pub internal_ext: Vec<u8>,
    #[prost(bool, tag = "9")]
    pub need_ack: bool,
}
#[derive(Clone, PartialEq, Message)]
pub struct Envelope {
    #[prost(bytes = "vec", tag = "1")]
    pub method: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    pub payload: Vec<u8>,
}
#[derive(Clone, PartialEq, Message)]
pub struct ChatMessage {
    #[prost(bytes = "vec", optional, tag = "2")]
    pub user: Option<Vec<u8>>,
    #[prost(bytes = "vec", tag = "3")]
    pub content: Vec<u8>,
}
#[derive(Clone, PartialEq, Message)]
pub struct User {
    #[prost(bytes = "vec", tag = "3")]
    pub nick_name: Vec<u8>,
}
#[derive(Clone, PartialEq, Message)]
pub struct RoomUserSeqMessage {
    #[prost(int64, tag = "7")]
    pub total_user: i64,
}
fn douyin(input: &[u8], out: &mut Batch) -> Result<()> {
    crate::protobuf::validate(input)?;
    let frame =
        PushFrame::decode(input).map_err(|_| Error::malformed("invalid Douyin push frame"))?;
    if frame.payload.is_empty() {
        return Ok(());
    }
    let bytes = if frame.payload_encoding == b"gzip" || frame.payload.starts_with(&[0x1f, 0x8b]) {
        out.inflate(flate2::read::GzDecoder::new(&frame.payload[..]))?
    } else if frame.payload_encoding.is_empty() || frame.payload_encoding == b"identity" {
        frame.payload
    } else {
        return Err(Error::malformed("unknown Douyin payload encoding"));
    };
    crate::protobuf::validate(&bytes)?;
    let response =
        Response::decode(&bytes[..]).map_err(|_| Error::malformed("invalid Douyin response"))?;
    if response.need_ack {
        std::str::from_utf8(&response.internal_ext)
            .map_err(|_| Error::malformed("invalid Douyin internalExt"))?;
        let ack = PushFrame {
            log_id: frame.log_id,
            payload_type: b"ack".to_vec(),
            payload: response.internal_ext,
            ..Default::default()
        };
        out.acks.push(Value::Bytes(ack.encode_to_vec()));
    }
    for message in response.messages {
        if let Err(e) = douyin_message(message, out) {
            if e.code == 2 {
                return Err(e);
            }
            out.diagnostic(e.message);
        }
    }
    Ok(())
}
fn douyin_message(bytes: Vec<u8>, out: &mut Batch) -> Result<()> {
    crate::protobuf::validate(&bytes)?;
    let envelope = Envelope::decode(bytes.as_slice())
        .map_err(|_| Error::malformed("invalid Douyin message envelope"))?;
    match envelope.method.as_slice() {
        b"WebcastChatMessage" => {
            crate::protobuf::validate(&envelope.payload)?;
            let message = ChatMessage::decode(envelope.payload.as_slice())
                .map_err(|_| Error::malformed("invalid Douyin chat"))?;
            let user_bytes = message.user.unwrap_or_default();
            crate::protobuf::validate(&user_bytes)?;
            let name = User::decode(user_bytes.as_slice())
                .map_err(|_| Error::malformed("invalid Douyin user"))?
                .nick_name;
            let name = std::str::from_utf8(&name)
                .map_err(|_| Error::malformed("invalid Douyin nickname UTF-8"))?;
            let text = std::str::from_utf8(&message.content)
                .map_err(|_| Error::malformed("invalid Douyin chat UTF-8"))?;
            out.event(chat(&utf16(name), &utf16(text), 0xffffff))?;
        }
        b"WebcastRoomUserSeqMessage" => {
            crate::protobuf::validate(&envelope.payload)?;
            let message = RoomUserSeqMessage::decode(envelope.payload.as_slice())
                .map_err(|_| Error::malformed("invalid Douyin online count"))?;
            out.event(online(message.total_user))?;
        }
        _ => {}
    }
    Ok(())
}

pub fn encode(request: &Value) -> Result<Value> {
    wire::version(request)?;
    let kind = request.get("kind").text()?;
    let bytes = match kind {
        "douyu" => {
            let units = request.get("text").units()?;
            let text = String::from_utf16_lossy(&units);
            let body = text.as_bytes();
            let size =
                u32::try_from(body.len() + 9).map_err(|_| Error::limit("Douyu encode limit"))?;
            let mut out = Vec::with_capacity(body.len() + 13);
            out.extend(size.to_le_bytes());
            out.extend(size.to_le_bytes());
            out.extend(689u16.to_le_bytes());
            out.extend([0, 0]);
            out.extend(body);
            out.push(0);
            out
        }
        "bili" => {
            let units = request.get("text").units()?;
            let text = String::from_utf16_lossy(&units);
            let body = text.as_bytes();
            let operation = u32::try_from(request.get("operation").u64()?)
                .map_err(|_| Error::request("invalid Bilibili operation"))?;
            let mut out = Vec::with_capacity(body.len() + 16);
            out.extend(((body.len() + 16) as u32).to_be_bytes());
            out.extend(16u16.to_be_bytes());
            out.extend(0u16.to_be_bytes());
            out.extend(operation.to_be_bytes());
            out.extend(1u32.to_be_bytes());
            out.extend(body);
            out
        }
        "huya_join" => {
            let mut body = Vec::new();
            tars::write_integer(&mut body, 0, request.get("ayyuid").i64()?);
            tars::write_integer(&mut body, 1, 1);
            tars::write_string(&mut body, 2, b"");
            tars::write_string(&mut body, 3, b"");
            tars::write_integer(&mut body, 4, request.get("top").i64()?);
            tars::write_integer(&mut body, 5, request.get("sub").i64()?);
            tars::write_integer(&mut body, 6, 0);
            tars::write_integer(&mut body, 7, 0);
            let mut out = Vec::new();
            tars::write_integer(&mut out, 0, 1);
            tars::write_bytes(&mut out, 1, &body);
            out
        }
        _ => return Err(Error::request("unsupported encode kind")),
    };
    Ok(wire::map([
        ("v", wire::int(1)),
        ("wire", Value::Bytes(bytes)),
    ]))
}
