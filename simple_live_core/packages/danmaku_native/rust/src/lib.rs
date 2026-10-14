//! Bounded native danmaku protocol and filtering workers.
//! Each session is owned by one Dart worker; calls must never overlap.
mod filter;
mod json;
mod protobuf;
pub mod protocols;
pub mod tars;
pub mod wire;

use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice,
};

pub const MAX_INPUT: usize = 4 * 1024 * 1024;
pub const MAX_DECOMPRESSED: usize = 16 * 1024 * 1024;
pub const MAX_OUTPUT: usize = 16 * 1024 * 1024;
pub const MAX_STRUCTURE_DEPTH: usize = 32;

#[derive(Debug)]
pub struct Error {
    pub code: i32,
    pub message: String,
}
pub type Result<T> = std::result::Result<T, Error>;
impl Error {
    pub fn malformed(message: impl Into<String>) -> Self {
        Self {
            code: 1,
            message: message.into(),
        }
    }
    pub fn limit(message: impl Into<String>) -> Self {
        Self {
            code: 2,
            message: message.into(),
        }
    }
    pub fn request(message: impl Into<String>) -> Self {
        Self {
            code: 3,
            message: message.into(),
        }
    }
}

pub struct Session {
    protocol: u32,
    malformed_count: u8,
    filter: filter::Filter,
}
impl Session {
    pub fn new(protocol: u32) -> Self {
        Self {
            protocol,
            malformed_count: 0,
            filter: filter::Filter::default(),
        }
    }
    pub fn decode(&mut self, bytes: &[u8]) -> (i32, wire::Value) {
        let mut batch = protocols::Batch::default();
        let result = if bytes.len() > MAX_INPUT {
            Err(Error::limit("input exceeds 4 MiB"))
        } else {
            protocols::decode(self.protocol, bytes, &mut batch)
        };
        let code = match result {
            Ok(()) => {
                self.malformed_count = 0;
                0
            }
            Err(error) => {
                if error.code == 1 {
                    self.malformed_count = self.malformed_count.saturating_add(1);
                }
                batch.fatal = error.code == 2 || self.malformed_count >= 3;
                batch.diagnostic(error.message);
                error.code
            }
        };
        (code, batch.value())
    }
}

#[repr(C)]
pub struct DmBuffer {
    pub data: *mut u8,
    pub len: usize,
}

fn error_value(error: &Error) -> wire::Value {
    wire::map([
        ("v", wire::int(1)),
        (
            "diagnostics",
            wire::Value::Array(vec![wire::Value::Text(error.message.clone())]),
        ),
        (
            "fatal",
            wire::Value::Bool(error.code == 2 || error.code == 4),
        ),
    ])
}

// Safety contract: pointers are valid for the stated sizes; output is writable;
// session handles and buffers are returned to this library exactly once. Invalid
// pointer provenance cannot be validated across a C ABI and is a caller error.
unsafe fn read_input<'a>(data: *const u8, len: usize, max: usize) -> Result<&'a [u8]> {
    if len > max {
        return Err(Error::limit("native request byte limit"));
    }
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err(Error::request("null input pointer"));
    }
    Ok(slice::from_raw_parts(data, len))
}
unsafe fn publish(out: *mut DmBuffer, value: &wire::Value) -> Result<()> {
    let bytes = wire::encode(value)?.into_boxed_slice();
    let len = bytes.len();
    let data = Box::into_raw(bytes) as *mut u8;
    ptr::write(out, DmBuffer { data, len });
    Ok(())
}
unsafe fn invoke(
    out: *mut DmBuffer,
    operation: impl FnOnce() -> Result<(i32, wire::Value)>,
) -> i32 {
    if out.is_null() {
        return 3;
    }
    ptr::write(
        out,
        DmBuffer {
            data: ptr::null_mut(),
            len: 0,
        },
    );
    let result = catch_unwind(AssertUnwindSafe(|| {
        let (code, value) = operation()?;
        publish(out, &value)?;
        Ok::<_, Error>(code)
    }));
    match result {
        Ok(Ok(code)) => code,
        other => {
            let error = match other {
                Ok(Err(e)) => e,
                Err(_) => Error {
                    code: 4,
                    message: "native worker panic".into(),
                },
                _ => unreachable!(),
            };
            // Also guard diagnostics allocation/serialization; no unwind may cross FFI.
            let _ = catch_unwind(AssertUnwindSafe(|| publish(out, &error_value(&error))));
            error.code
        }
    }
}

#[no_mangle]
pub extern "C" fn dm_abi_version() -> u32 {
    1
}

#[no_mangle]
pub extern "C" fn dm_create(protocol: u32) -> *mut Session {
    catch_unwind(AssertUnwindSafe(|| {
        if protocol <= 4 {
            Box::into_raw(Box::new(Session::new(protocol)))
        } else {
            ptr::null_mut()
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
/// # Safety
/// `session` must be null or a live, exclusively owned handle from `dm_create`.
pub unsafe extern "C" fn dm_reset(session: *mut Session) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(session) = session.as_mut() else {
            return 3;
        };
        session.malformed_count = 0;
        0
    }))
    .unwrap_or(4)
}

#[no_mangle]
/// # Safety
/// A non-null handle must be live, exclusively owned, and disposed exactly once.
pub unsafe extern "C" fn dm_dispose(session: *mut Session) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !session.is_null() {
            drop(Box::from_raw(session));
        }
    }));
}

#[no_mangle]
/// # Safety
/// The handle must be live and exclusively owned. `data` must be readable for
/// `len` bytes and `out` writable. Release the returned buffer exactly once.
pub unsafe extern "C" fn dm_decode_batch(
    session: *mut Session,
    data: *const u8,
    len: usize,
    out: *mut DmBuffer,
) -> i32 {
    invoke(out, || {
        let session = session
            .as_mut()
            .ok_or_else(|| Error::request("null session"))?;
        let bytes = read_input(data, len, MAX_INPUT)?;
        Ok(session.decode(bytes))
    })
}

#[no_mangle]
/// # Safety
/// The handle must be live and exclusively owned. `data` must be readable for
/// `len` bytes and `out` writable. Release the returned buffer exactly once.
pub unsafe extern "C" fn dm_replace_rules(
    session: *mut Session,
    data: *const u8,
    len: usize,
    out: *mut DmBuffer,
) -> i32 {
    invoke(out, || {
        let session = session
            .as_mut()
            .ok_or_else(|| Error::request("null session"))?;
        let input = wire::decode(read_input(data, len, MAX_OUTPUT)?)?;
        Ok((0, session.filter.replace(&input)?))
    })
}

#[no_mangle]
/// # Safety
/// The handle must be live and exclusively owned. `data` must be readable for
/// `len` bytes and `out` writable. Release the returned buffer exactly once.
pub unsafe extern "C" fn dm_filter_batch(
    session: *mut Session,
    data: *const u8,
    len: usize,
    out: *mut DmBuffer,
) -> i32 {
    invoke(out, || {
        let session = session
            .as_mut()
            .ok_or_else(|| Error::request("null session"))?;
        let input = wire::decode(read_input(data, len, MAX_INPUT)?)?;
        Ok((0, session.filter.apply(&input)?))
    })
}

#[no_mangle]
/// # Safety
/// The handle must be live and exclusively owned. `data` must be readable for
/// `len` bytes and `out` writable. Release the returned buffer exactly once.
pub unsafe extern "C" fn dm_encode(
    session: *mut Session,
    data: *const u8,
    len: usize,
    out: *mut DmBuffer,
) -> i32 {
    invoke(out, || {
        if session.is_null() {
            return Err(Error::request("null session"));
        }
        let input = wire::decode(read_input(data, len, MAX_INPUT)?)?;
        Ok((0, protocols::encode(&input)?))
    })
}

#[no_mangle]
/// # Safety
/// Non-null `data` and `len` must be the exact pair returned by this library,
/// not previously freed. No other thread may access the buffer during release.
pub unsafe extern "C" fn dm_free_buffer(data: *mut u8, len: usize) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !data.is_null() {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(data, len)));
        }
    }));
}

#[cfg(test)]
mod tests;
