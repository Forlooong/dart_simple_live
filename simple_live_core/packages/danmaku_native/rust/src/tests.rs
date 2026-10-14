use super::*;
use prost::Message;
use std::io::Write;
use wire::{int, map, text, units, Value};

fn bili_packet(version: u16, op: u32, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend(((body.len() + 16) as u32).to_be_bytes());
    out.extend(16u16.to_be_bytes());
    out.extend(version.to_be_bytes());
    out.extend(op.to_be_bytes());
    out.extend(1u32.to_be_bytes());
    out.extend(body);
    out
}
fn bili_chat(body: &str) -> Vec<u8> {
    bili_packet(0, 5, body.as_bytes())
}
const CHAT: &str = r#"{"cmd":"DANMU_MSG","info":[[0,0,0,16711680],"你好😀",[1,"观众"]]}"#;
fn zlib(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}
fn gzip(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}
fn events(result: &Value) -> &[Value] {
    result.get("events").array().unwrap()
}
fn decode(protocol: u32, bytes: &[u8]) -> Value {
    let (code, result) = Session::new(protocol).decode(bytes);
    assert_eq!(code, 0, "{result:?}");
    result
}
fn str_units(v: &Value) -> Vec<u16> {
    v.units().unwrap()
}

#[test]
fn bilibili_multiple_packets_use_header_lengths() {
    let mut packet = bili_chat(CHAT);
    packet.extend(bili_packet(1, 3, &12345u32.to_be_bytes()));
    // A future header extension must not be treated as JSON.
    let mut extended = bili_chat(CHAT);
    extended.splice(16..16, [0xaa, 0xbb, 0xcc, 0xdd]);
    let length = extended.len() as u32;
    extended[..4].copy_from_slice(&length.to_be_bytes());
    extended[4..6].copy_from_slice(&20u16.to_be_bytes());
    packet.extend(extended);
    let result = decode(1, &packet);
    assert_eq!(events(&result).len(), 3);
    assert_eq!(
        str_units(events(&result)[0].get("text")),
        "你好😀".encode_utf16().collect::<Vec<_>>()
    );
    assert_eq!(events(&result)[0].get("color").i64().unwrap(), 0xff0000);
    assert_eq!(events(&result)[1].get("online").i64().unwrap(), 12345);
}
#[test]
fn bilibili_zlib_brotli_and_nested_packets() {
    let inner = bili_chat(CHAT);
    let z = bili_packet(2, 5, &zlib(&inner));
    let mut compressor = brotli::CompressorWriter::new(Vec::new(), 4096, 4, 22);
    compressor.write_all(&z).unwrap();
    let compressed = compressor.into_inner();
    let result = decode(1, &bili_packet(3, 5, &compressed));
    assert_eq!(events(&result).len(), 1);
}
#[test]
fn bilibili_json_preserves_surrogates_and_malformed_utf8_policy() {
    let packet = bili_chat(r#"{"cmd":"DANMU_MSG","info":[[0,0,0,0],"\ud800x\udfff",[0,"a"]]}"#);
    let result = decode(1, &packet);
    assert_eq!(
        str_units(events(&result)[0].get("text")),
        vec![0xd800, 120, 0xdfff]
    );
    let mut malformed = br#"{"cmd":"DANMU_MSG","info":[[0,0,0,0],"x",[0,"a"]]}"#.to_vec();
    let at = malformed.iter().position(|b| *b == b'x').unwrap();
    malformed[at] = 0xff;
    let result = decode(1, &bili_packet(0, 5, &malformed));
    assert_eq!(str_units(events(&result)[0].get("text")), vec![0xfffd]);
}
#[test]
fn bilibili_bad_json_isolated_and_superchat_fields_retained() {
    let mut packet = bili_chat("{");
    packet.extend(bili_chat(r##"{"cmd":"SUPER_CHAT_MESSAGE","data":{"message":"hi","price":30,"start_time":1700000000,"end_time":1700000060,"background_color":"#112233","background_bottom_color":"#445566","user_info":{"uname":"name","face":"url"}}}"##));
    packet.extend(bili_chat(CHAT));
    let result = decode(1, &packet);
    assert_eq!(events(&result).len(), 2);
    assert_eq!(result.get("diagnostics").array().unwrap().len(), 1);
    let sc = events(&result)[0].get("sc");
    assert_eq!(sc.get("start").i64().unwrap(), 1700000000000);
    assert_eq!(
        str_units(sc.get("face")),
        "url@200w.jpg".encode_utf16().collect::<Vec<_>>()
    );
}
#[test]
fn limits_and_malformed_reset_are_explicit() {
    let mut session = Session::new(1);
    for n in 1..=3 {
        let (code, result) = session.decode(&[0]);
        assert_eq!(code, 1);
        assert_eq!(result.get("fatal").bool().unwrap(), n == 3);
    }
    assert_eq!(session.decode(&bili_chat(CHAT)).0, 0);
    assert!(!session.decode(&[0]).1.get("fatal").bool().unwrap());
    let (code, result) = session.decode(&vec![0; MAX_INPUT + 1]);
    assert_eq!(code, 2);
    assert!(result.get("fatal").bool().unwrap());
    let compressed = zlib(&vec![0; MAX_DECOMPRESSED + 1]);
    assert_eq!(session.decode(&bili_packet(2, 5, &compressed)).0, 2);
    let mut nested = bili_chat(CHAT);
    for _ in 0..5 {
        nested = bili_packet(2, 5, &zlib(&nested));
    }
    assert_eq!(session.decode(&nested).0, 2);
}

#[test]
fn superchat_outside_dart_datetime_range_is_isolated() {
    let mut packet = bili_chat(
        r#"{"cmd":"SUPER_CHAT_MESSAGE","data":{"price":1,"start_time":999999999999999,"end_time":1,"user_info":{}}}"#,
    );
    packet.extend(bili_chat(CHAT));
    let result = decode(1, &packet);
    assert_eq!(events(&result).len(), 1);
    assert_eq!(events(&result)[0].get("type").i64().unwrap(), 0);
    assert_eq!(result.get("diagnostics").array().unwrap().len(), 1);
}
fn encode_request(kind: &str, body: &str) -> Vec<u8> {
    protocols::encode(&map([
        ("v", int(1)),
        ("kind", Value::Text(kind.into())),
        ("text", text(body)),
    ]))
    .unwrap()
    .get("wire")
    .bytes()
    .unwrap()
    .to_vec()
}
#[test]
fn douyu_multibyte_length_multi_packet_and_single_escape() {
    let mut packet = encode_request(
        "douyu",
        "type@=chatmsg/dms@=1/nn@=中文/txt@=甲@AS乙@S丙/col@=2/",
    );
    assert_eq!(
        u32::from_le_bytes(packet[..4].try_into().unwrap()) as usize,
        packet.len() - 4
    );
    packet.extend(encode_request(
        "douyu",
        "type@=chatmsg/nn@=hidden/txt@=hidden/",
    ));
    packet.extend(encode_request(
        "douyu",
        "type@=chatmsg/dms@=0/nn@=b/txt@=ok/col@=6/",
    ));
    let result = decode(2, &packet);
    assert_eq!(events(&result).len(), 2);
    assert_eq!(
        str_units(events(&result)[0].get("text")),
        "甲@S乙/丙".encode_utf16().collect::<Vec<_>>()
    );
    assert_eq!(events(&result)[0].get("color").i64().unwrap(), 0x1e87f0);
}
#[test]
fn douyu_bad_length_stops_payload_and_invalid_utf8_does_not_lose_next_packet() {
    let valid = encode_request("douyu", "type@=chatmsg/dms@=1/txt@=ok/nn@=a/");
    let mut bad = valid.clone();
    bad[4] ^= 1;
    assert_eq!(Session::new(2).decode(&bad).0, 1);
    let mut bad = valid.clone();
    bad[12] = 0xff;
    bad.extend(valid);
    let result = decode(2, &bad);
    assert_eq!(events(&result).len(), 1);
    assert_eq!(result.get("diagnostics").array().unwrap().len(), 1);
}
fn huya_frame(uri: i64, body: &[u8]) -> Vec<u8> {
    let mut push = Vec::new();
    tars::write_integer(&mut push, 0, 0);
    tars::write_integer(&mut push, 1, uri);
    tars::write_bytes(&mut push, 2, body);
    let mut command = Vec::new();
    tars::write_integer(&mut command, 0, 7);
    tars::write_bytes(&mut command, 1, &push);
    command
}
#[test]
fn huya_unknown_tars_fields_and_chat_online() {
    let mut body = vec![0x0a];
    tars::write_integer(&mut body, 0, 123);
    tars::write_integer(&mut body, 1, 456);
    tars::write_string(&mut body, 2, "昵称".as_bytes());
    body.push(0x0b);
    // Unknown map, list, float, double, extended tag and nested struct.
    body.extend([0x18, 0x00, 1, 0x06, 1, b'k', 0x09, 0x00, 1, 0x0c]);
    body.extend([0x24, 0, 0, 0, 0]);
    tars::write_string(&mut body, 3, "弹幕".as_bytes());
    body.extend([0x45, 0, 0, 0, 0, 0, 0, 0, 0]);
    body.extend([0x5a, 0x0c, 0x0b]);
    body.push(0x6a);
    tars::write_integer(&mut body, 0, 0xabcdef);
    body.push(0x0b);
    tars::write_integer(&mut body, 17, 5);
    let result = decode(3, &huya_frame(1400, &body));
    assert_eq!(
        str_units(events(&result)[0].get("user")),
        "昵称".encode_utf16().collect::<Vec<_>>()
    );
    assert_eq!(events(&result)[0].get("color").i64().unwrap(), 0xabcdef);
    let mut count = Vec::new();
    tars::write_integer(&mut count, 0, 987654);
    let result = decode(3, &huya_frame(8006, &count));
    assert_eq!(events(&result)[0].get("online").i64().unwrap(), 987654);
}
#[test]
fn huya_join_distinguishes_top_and_sub_sid() {
    let result = protocols::encode(&map([
        ("v", int(1)),
        ("kind", Value::Text("huya_join".into())),
        ("ayyuid", int(11)),
        ("top", int(22)),
        ("sub", int(33)),
    ]))
    .unwrap();
    let command = tars::parse(result.get("wire").bytes().unwrap()).unwrap();
    let body = tars::parse(tars::bytes(&command, 1).unwrap()).unwrap();
    assert_eq!(tars::integer(&body, 4), Some(22));
    assert_eq!(tars::integer(&body, 5), Some(33));
}
#[test]
fn tars_limits_and_truncation_do_not_panic() {
    assert!(tars::parse(&[0x0d, 0, 0x02, 0x7f, 0xff, 0xff, 0xff]).is_err());
    assert!(tars::parse(&[0x07, 0xff, 0xff, 0xff, 0xff]).is_err());
    let mut nested = vec![0x0a; 34];
    nested.extend(vec![0x0b; 34]);
    assert_eq!(tars::parse(&nested).unwrap_err().code, 2);
}
fn douyin_response() -> protocols::Response {
    use protocols::*;
    Response {
        need_ack: true,
        internal_ext: "扩展".as_bytes().to_vec(),
        messages: vec![
            Envelope {
                method: b"WebcastChatMessage".to_vec(),
                payload: ChatMessage {
                    user: Some(
                        User {
                            nick_name: b"name".to_vec(),
                        }
                        .encode_to_vec(),
                    ),
                    content: "消息".as_bytes().to_vec(),
                }
                .encode_to_vec(),
            }
            .encode_to_vec(),
            Envelope {
                method: b"WebcastChatMessage".to_vec(),
                payload: vec![0xff],
            }
            .encode_to_vec(),
            Envelope {
                method: b"WebcastRoomUserSeqMessage".to_vec(),
                payload: RoomUserSeqMessage { total_user: 123 }.encode_to_vec(),
            }
            .encode_to_vec(),
        ],
    }
}
#[test]
fn douyin_ack_retains_uint64_and_internal_ext_before_bad_chat() {
    let response = douyin_response();
    for compressed in [false, true] {
        let bytes = response.encode_to_vec();
        let frame = protocols::PushFrame {
            log_id: u64::MAX - 7,
            payload: if compressed { gzip(&bytes) } else { bytes },
            ..Default::default()
        };
        let result = decode(4, &frame.encode_to_vec());
        assert_eq!(events(&result).len(), 2);
        let ack =
            protocols::PushFrame::decode(result.get("acks").array().unwrap()[0].bytes().unwrap())
                .unwrap();
        assert_eq!(ack.log_id, u64::MAX - 7);
        assert_eq!(ack.payload_type, b"ack");
        assert_eq!(ack.payload, "扩展".as_bytes());
        assert_eq!(result.get("diagnostics").array().unwrap().len(), 1);
    }
}
#[test]
fn douyin_invalid_utf8_isolated_to_message() {
    let mut response = douyin_response();
    response.messages[0] = protocols::Envelope {
        method: b"WebcastChatMessage".to_vec(),
        payload: protocols::ChatMessage {
            user: None,
            content: vec![0xff],
        }
        .encode_to_vec(),
    }
    .encode_to_vec();
    let frame = protocols::PushFrame {
        payload: response.encode_to_vec(),
        ..Default::default()
    };
    let result = decode(4, &frame.encode_to_vec());
    assert_eq!(events(&result).len(), 1);
    assert_eq!(events(&result)[0].get("type").i64().unwrap(), 2);
}

#[test]
fn douyin_bad_envelope_isolated_and_protobuf_groups_bounded() {
    let mut response = douyin_response();
    response.messages.push(vec![0xff]);
    let frame = protocols::PushFrame {
        log_id: 42,
        payload: response.encode_to_vec(),
        ..Default::default()
    };
    let result = decode(4, &frame.encode_to_vec());
    assert_eq!(events(&result).len(), 2);
    assert_eq!(result.get("acks").array().unwrap().len(), 1);
    let mut groups = vec![0x0b; 33];
    groups.extend(vec![0x0c; 33]);
    assert_eq!(Session::new(4).decode(&groups).0, 2);
    let unknown = decode(3, &huya_frame(123456, &[0xff]));
    assert!(events(&unknown).is_empty());
    let mut huya_session = Session::new(3);
    for _ in 0..4 {
        let (status, result) = huya_session.decode(&huya_frame(1400, &[0xff]));
        assert_eq!(status, 0);
        assert!(!result.get("fatal").bool().unwrap());
        assert_eq!(result.get("diagnostics").array().unwrap().len(), 1);
    }
}
fn rules(version: u64, list: Vec<(bool, Vec<u16>)>) -> Value {
    map([
        ("v", int(1)),
        ("version", int(version)),
        (
            "rules",
            Value::Array(
                list.into_iter()
                    .map(|(regex, text)| {
                        map([("regex", Value::Bool(regex)), ("text", units(&text))])
                    })
                    .collect(),
            ),
        ),
    ])
}
fn strings(list: &[&str]) -> Vec<Vec<u16>> {
    list.iter().map(|s| s.encode_utf16().collect()).collect()
}
fn filter_apply(filter: &mut filter::Filter, version: u64, texts: Vec<Vec<u16>>) -> Value {
    filter
        .apply(&map([
            ("v", int(1)),
            ("version", int(version)),
            (
                "texts",
                Value::Array(texts.iter().map(|s| units(s)).collect()),
            ),
        ]))
        .unwrap()
}
fn keep(v: &Value) -> Vec<bool> {
    v.get("keep")
        .array()
        .unwrap()
        .iter()
        .map(|b| b.bool().unwrap())
        .collect()
}
#[test]
fn literals_match_utf16_boundaries_and_lone_surrogates() {
    let mut f = filter::Filter::default();
    f.replace(&rules(
        1,
        vec![(false, vec![0x6261]), (false, vec![0xd800])],
    ))
    .unwrap();
    let r = filter_apply(
        &mut f,
        1,
        vec![
            vec![0x6100, 0x0062],
            vec![0x6100, 0x0062, 0x6261],
            vec![0xd800],
            vec![0xfffd],
        ],
    );
    assert_eq!(keep(&r), vec![true, false, false, true]);
}
#[test]
fn regex_ucs2_ecmascript_examples() {
    let cases = [
        (r"^.$", "😀", false),
        (r"^..$", "😀", true),
        (r"(?<=foo)bar", "foobar", true),
        (r"(a)\1", "aa", true),
        (r"\141", "a", true),
        (r"\q", "q", true),
        (r"^a$", "a\n", false),
        (r"\b中文\b", "中文", false),
    ];
    for (pattern, hay, matched) in cases {
        let mut f = filter::Filter::default();
        let install = f
            .replace(&rules(1, vec![(true, pattern.encode_utf16().collect())]))
            .unwrap();
        assert!(
            install.get("unsupported").array().unwrap().is_empty(),
            "{pattern}"
        );
        let r = filter_apply(&mut f, 1, strings(&[hay]));
        assert_eq!(keep(&r), vec![!matched], "{pattern} vs {hay}");
    }
    let mut f = filter::Filter::default();
    f.replace(&rules(1, vec![(true, vec![0xd800])])).unwrap();
    assert_eq!(
        keep(&filter_apply(&mut f, 1, vec![vec![0xd800], vec![0xfffd]])),
        vec![false, true]
    );
}
#[test]
fn regex_backtracking_budget_quarantines_once_until_replace() {
    let mut f = filter::Filter::default();
    f.replace(&rules(5, vec![(true, r"^(a+)+$".encode_utf16().collect())]))
        .unwrap();
    let bad = "a".repeat(40) + "!";
    let r = filter_apply(&mut f, 5, strings(&["safe", &bad]));
    assert!(r.get("quarantined").bool().unwrap());
    assert_eq!(keep(&r), vec![false, false]);
    assert_eq!(r.get("diagnostics").array().unwrap().len(), 1);
    let r = filter_apply(&mut f, 5, strings(&["safe"]));
    assert!(r.get("quarantined").bool().unwrap());
    assert!(r.get("diagnostics").array().unwrap().is_empty());
    f.replace(&rules(6, Vec::new())).unwrap();
    assert_eq!(
        keep(&filter_apply(&mut f, 6, strings(&["safe"]))),
        vec![true]
    );
}
#[test]
fn rules_unsupported_limits_and_version_barrier() {
    let mut f = filter::Filter::default();
    let install = f
        .replace(&rules(2, vec![(true, "[".encode_utf16().collect())]))
        .unwrap();
    assert_eq!(install.get("unsupported").array().unwrap(), &[int(0)]);
    let request = map([
        ("v", int(1)),
        ("version", int(1)),
        ("texts", Value::Array(vec![])),
    ]);
    assert_eq!(f.apply(&request).unwrap_err().code, 3);
    let install = f.replace(&rules(3, vec![(false, vec![65; 4097])])).unwrap();
    assert!(install.get("blocked").bool().unwrap());
    assert!(filter_apply(&mut f, 3, strings(&["safe"]))
        .get("quarantined")
        .bool()
        .unwrap());
    let oversized = vec![(false, vec![65; 4096]); 129];
    let result = f.replace(&rules(4, oversized)).unwrap();
    assert!(result.get("blocked").bool().unwrap());
    assert!(filter_apply(&mut f, 4, strings(&["safe"]))
        .get("quarantined")
        .bool()
        .unwrap());
}
#[test]
fn cbor_roundtrip_and_malicious_structure_limits() {
    let value = map([
        ("v", int(1)),
        ("u64", int(u64::MAX)),
        ("i64", int(i64::MIN)),
        ("text", units(&[0xd800, 0xdfff])),
        ("empty", Value::Array(vec![])),
    ]);
    assert_eq!(wire::decode(&wire::encode(&value).unwrap()).unwrap(), value);
    assert!(wire::decode(&[0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]).is_err());
    let mut nested = vec![0x81; 34];
    nested.push(0xf6);
    assert_eq!(wire::decode(&nested).unwrap_err().code, 2);
}
#[test]
fn ffi_ownership_status_and_reset() {
    unsafe {
        assert_eq!(dm_abi_version(), 1);
        let session = dm_create(1);
        assert!(!session.is_null());
        let mut out = DmBuffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let packet = bili_chat(CHAT);
        assert_eq!(
            dm_decode_batch(session, packet.as_ptr(), packet.len(), &mut out),
            0
        );
        let result = wire::decode(std::slice::from_raw_parts(out.data, out.len)).unwrap();
        assert_eq!(events(&result).len(), 1);
        dm_free_buffer(out.data, out.len);
        assert_eq!(dm_reset(session), 0);
        assert_eq!(dm_decode_batch(session, std::ptr::null(), 1, &mut out), 3);
        assert!(!out.data.is_null());
        dm_free_buffer(out.data, out.len);
        dm_dispose(session);
        dm_dispose(std::ptr::null_mut());
        dm_free_buffer(std::ptr::null_mut(), 0);
    }
}
#[test]
fn random_malformed_inputs_do_not_panic() {
    let mut state = 0xdeadbeefu32;
    for size in 0..512 {
        let mut data = Vec::with_capacity(size);
        for _ in 0..size {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            data.push((state >> 24) as u8);
        }
        for protocol in 1..=4 {
            let _ = Session::new(protocol).decode(&data);
        }
        let _ = wire::decode(&data);
    }
}
