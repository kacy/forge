//! String operations for the Forge runtime
//!
//! Forge strings are immutable, length-prefixed, and reference-counted.
//! They use the following layout:
//! ```
//! [RC Header][forge_string_t: { ptr, len, is_heap }][String Data...]
//! ```

use crate::arc::{forge_rc_alloc, forge_rc_release, forge_rc_retain, TypeTag};
use std::slice;

/// Forge string representation - compatible with C struct
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ForgeString {
    /// Pointer to UTF-8 data (may be static or heap-allocated)
    pub ptr: *const u8,
    /// Length in bytes (NOT character count)
    pub len: i64,
    /// Whether this string is heap-allocated and needs RC
    pub is_heap: bool,
}

// SAFETY: ForgeString is immutable after creation, so it's safe to share between threads
unsafe impl Send for ForgeString {}
unsafe impl Sync for ForgeString {}

/// Static empty string
pub static EMPTY_STRING: ForgeString = ForgeString {
    ptr: b"".as_ptr(),
    len: 0,
    is_heap: false,
};

/// Create a new heap-allocated string by copying data
/// 
/// # Safety
/// data must be valid UTF-8
#[no_mangle]
pub unsafe extern "C" fn forge_string_new(data: *const u8, len: i64) -> ForgeString {
    if len <= 0 {
        return EMPTY_STRING;
    }
    
    // Allocate with RC header
    let size = len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    if mem.is_null() {
        return EMPTY_STRING;
    }
    
    // Copy data
    std::ptr::copy_nonoverlapping(data, mem.add(std::mem::size_of::<ForgeString>()), len as usize);
    
    // Create the string struct inline
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = mem.add(std::mem::size_of::<ForgeString>());
    (*str_ptr).len = len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Create a string from a C string (null-terminated)
#[no_mangle]
pub unsafe extern "C" fn forge_string_from_cstr(cstr: *const i8) -> ForgeString {
    if cstr.is_null() {
        return EMPTY_STRING;
    }
    
    let len = strlen(cstr);
    forge_string_new(cstr as *const u8, len as i64)
}

/// Retain a string (increment RC if heap-allocated)
#[no_mangle]
pub unsafe extern "C" fn forge_string_retain(s: ForgeString) {
    if s.is_heap && !s.ptr.is_null() {
        // Get pointer to RC header via the string struct location
        let str_struct_ptr = (s.ptr as *mut u8).sub(std::mem::size_of::<ForgeString>()) as *mut ForgeString;
        forge_rc_retain(str_struct_ptr as *mut u8);
    }
}

/// Release a string (decrement RC, free if zero)
#[no_mangle]
pub unsafe extern "C" fn forge_string_release(s: ForgeString) {
    if !s.is_heap || s.ptr.is_null() {
        return;
    }
    
    // Get pointer to the inline ForgeString struct
    let str_struct_ptr = (s.ptr as *mut u8).sub(std::mem::size_of::<ForgeString>()) as *mut ForgeString;
    
    // Release with custom destructor
    forge_rc_release(str_struct_ptr as *mut u8, Some(forge_string_destructor));
}

/// Destructor for string memory
extern "C" fn forge_string_destructor(ptr: *mut u8) {
    // Nothing special needed - the memory is freed by arc::forge_rc_release
    let _ = ptr;
}

extern "C" {
    fn strlen(s: *const i8) -> usize;
}

/// Concatenate two strings
#[no_mangle]
pub unsafe extern "C" fn forge_string_concat(a: ForgeString, b: ForgeString) -> ForgeString {
    let new_len = a.len + b.len;
    if new_len == 0 {
        return EMPTY_STRING;
    }
    
    let size = new_len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    // Copy both strings
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    std::ptr::copy_nonoverlapping(a.ptr, data_ptr, a.len as usize);
    std::ptr::copy_nonoverlapping(b.ptr, data_ptr.add(a.len as usize), b.len as usize);
    
    // Create string struct inline
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = new_len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Check string equality
#[no_mangle]
pub extern "C" fn forge_string_eq(a: ForgeString, b: ForgeString) -> bool {
    if a.len != b.len {
        return false;
    }
    if a.len == 0 {
        return true;
    }
    unsafe {
        let a_slice = slice::from_raw_parts(a.ptr, a.len as usize);
        let b_slice = slice::from_raw_parts(b.ptr, b.len as usize);
        a_slice == b_slice
    }
}

/// Check string inequality
#[no_mangle]
pub extern "C" fn forge_string_neq(a: ForgeString, b: ForgeString) -> bool {
    !forge_string_eq(a, b)
}

/// String less-than comparison (lexicographic)
#[no_mangle]
pub extern "C" fn forge_string_lt(a: ForgeString, b: ForgeString) -> bool {
    unsafe {
        let a_slice = slice::from_raw_parts(a.ptr, a.len as usize);
        let b_slice = slice::from_raw_parts(b.ptr, b.len as usize);
        a_slice < b_slice
    }
}

/// String greater-than comparison (lexicographic)
#[no_mangle]
pub extern "C" fn forge_string_gt(a: ForgeString, b: ForgeString) -> bool {
    forge_string_lt(b, a)
}

/// String less-than-or-equal comparison (lexicographic)
#[no_mangle]
pub extern "C" fn forge_string_lte(a: ForgeString, b: ForgeString) -> bool {
    !forge_string_gt(a, b)
}

/// String greater-than-or-equal comparison (lexicographic)
#[no_mangle]
pub extern "C" fn forge_string_gte(a: ForgeString, b: ForgeString) -> bool {
    !forge_string_lt(a, b)
}

/// Get string length in bytes
#[no_mangle]
pub extern "C" fn forge_string_len(s: ForgeString) -> i64 {
    s.len
}

/// Create substring
#[no_mangle]
pub unsafe extern "C" fn forge_string_substring(s: ForgeString, start: i64, end: i64) -> ForgeString {
    if start < 0 || end > s.len || start >= end {
        return EMPTY_STRING;
    }
    
    let new_len = end - start;
    let size = new_len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    std::ptr::copy_nonoverlapping(s.ptr.add(start as usize), data_ptr, new_len as usize);
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = new_len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Check if string contains substring
#[no_mangle]
pub extern "C" fn forge_string_contains(haystack: ForgeString, needle: ForgeString) -> bool {
    if needle.len == 0 {
        return true;
    }
    if needle.len > haystack.len {
        return false;
    }
    
    unsafe {
        let hay = slice::from_raw_parts(haystack.ptr, haystack.len as usize);
        let need = slice::from_raw_parts(needle.ptr, needle.len as usize);
        
        for i in 0..=haystack.len - needle.len {
            if &hay[i as usize..(i + needle.len) as usize] == need {
                return true;
            }
        }
    }
    false
}

/// Check if string starts with prefix
#[no_mangle]
pub extern "C" fn forge_string_starts_with(s: ForgeString, prefix: ForgeString) -> bool {
    if prefix.len > s.len {
        return false;
    }
    if prefix.len == 0 {
        return true;
    }
    unsafe {
        let s_slice = slice::from_raw_parts(s.ptr, prefix.len as usize);
        let p_slice = slice::from_raw_parts(prefix.ptr, prefix.len as usize);
        s_slice == p_slice
    }
}

/// Check if string ends with suffix
#[no_mangle]
pub extern "C" fn forge_string_ends_with(s: ForgeString, suffix: ForgeString) -> bool {
    if suffix.len > s.len {
        return false;
    }
    if suffix.len == 0 {
        return true;
    }
    unsafe {
        let start = (s.len - suffix.len) as usize;
        let s_slice = slice::from_raw_parts(s.ptr.add(start), suffix.len as usize);
        let suf_slice = slice::from_raw_parts(suffix.ptr, suffix.len as usize);
        s_slice == suf_slice
    }
}

/// Trim whitespace from both ends
#[no_mangle]
pub extern "C" fn forge_string_trim(s: ForgeString) -> ForgeString {
    if s.len == 0 {
        return EMPTY_STRING;
    }
    
    unsafe {
        let data = slice::from_raw_parts(s.ptr, s.len as usize);
        
        // Find start (skip leading whitespace)
        let mut start = 0;
        while start < data.len() && (data[start] == b' ' || data[start] == b'\t' || data[start] == b'\n' || data[start] == b'\r') {
            start += 1;
        }
        
        // Find end (skip trailing whitespace)
        let mut end = data.len();
        while end > start && (data[end - 1] == b' ' || data[end - 1] == b'\t' || data[end - 1] == b'\n' || data[end - 1] == b'\r') {
            end -= 1;
        }
        
        let new_len = (end - start) as i64;
        if new_len <= 0 {
            return EMPTY_STRING;
        }
        
        let size = new_len as usize + std::mem::size_of::<ForgeString>();
        let mem = forge_rc_alloc(size, TypeTag::String as u32);
        
        let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
        std::ptr::copy_nonoverlapping(s.ptr.add(start), data_ptr, new_len as usize);
        
        let str_ptr = mem as *mut ForgeString;
        (*str_ptr).ptr = data_ptr;
        (*str_ptr).len = new_len;
        (*str_ptr).is_heap = true;
        
        *str_ptr
    }
}

/// Convert to uppercase
#[no_mangle]
pub unsafe extern "C" fn forge_string_to_upper(s: ForgeString) -> ForgeString {
    if s.len == 0 {
        return EMPTY_STRING;
    }
    
    let size = s.len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    let src = slice::from_raw_parts(s.ptr, s.len as usize);
    
    for (i, &byte) in src.iter().enumerate() {
        *data_ptr.add(i) = if byte >= b'a' && byte <= b'z' {
            byte - 32
        } else {
            byte
        };
    }
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = s.len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Convert to lowercase
#[no_mangle]
pub unsafe extern "C" fn forge_string_to_lower(s: ForgeString) -> ForgeString {
    if s.len == 0 {
        return EMPTY_STRING;
    }
    
    let size = s.len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    let src = slice::from_raw_parts(s.ptr, s.len as usize);
    
    for (i, &byte) in src.iter().enumerate() {
        *data_ptr.add(i) = if byte >= b'A' && byte <= b'Z' {
            byte + 32
        } else {
            byte
        };
    }
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = s.len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Find index of substring (returns -1 if not found)
#[no_mangle]
pub extern "C" fn forge_string_index_of(haystack: ForgeString, needle: ForgeString) -> i64 {
    if needle.len == 0 {
        return 0;
    }
    if needle.len > haystack.len {
        return -1;
    }
    
    unsafe {
        let hay = slice::from_raw_parts(haystack.ptr, haystack.len as usize);
        let need = slice::from_raw_parts(needle.ptr, needle.len as usize);
        
        for i in 0..=haystack.len - needle.len {
            if &hay[i as usize..(i + needle.len) as usize] == need {
                return i;
            }
        }
    }
    -1
}

/// Find last index of substring (returns -1 if not found)
#[no_mangle]
pub extern "C" fn forge_string_last_index_of(haystack: ForgeString, needle: ForgeString) -> i64 {
    if needle.len == 0 {
        return haystack.len;
    }
    if needle.len > haystack.len {
        return -1;
    }
    
    unsafe {
        let hay = slice::from_raw_parts(haystack.ptr, haystack.len as usize);
        let need = slice::from_raw_parts(needle.ptr, needle.len as usize);
        
        let mut i = haystack.len - needle.len;
        loop {
            if &hay[i as usize..(i + needle.len) as usize] == need {
                return i;
            }
            if i == 0 {
                break;
            }
            i -= 1;
        }
    }
    -1
}

/// Repeat string n times
#[no_mangle]
pub unsafe extern "C" fn forge_string_repeat(s: ForgeString, n: i64) -> ForgeString {
    if n <= 0 || s.len == 0 {
        return EMPTY_STRING;
    }
    
    let new_len = s.len * n;
    let size = new_len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    let src = slice::from_raw_parts(s.ptr, s.len as usize);
    
    for i in 0..n as usize {
        std::ptr::copy_nonoverlapping(src.as_ptr(), data_ptr.add(i * s.len as usize), s.len as usize);
    }
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = new_len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Replace all occurrences of old with new_s
#[no_mangle]
pub unsafe extern "C" fn forge_string_replace(s: ForgeString, old: ForgeString, new_s: ForgeString) -> ForgeString {
    if old.len == 0 || s.len == 0 {
        return s;
    }
    
    // Count occurrences
    let mut count = 0;
    let mut pos = 0;
    while pos <= s.len - old.len {
        if forge_string_contains(
            ForgeString { ptr: s.ptr.add(pos as usize), len: s.len - pos, is_heap: false },
            old
        ) {
            count += 1;
            pos += old.len;
        } else {
            pos += 1;
        }
    }
    
    if count == 0 {
        // No matches, return copy of original
        return forge_string_substring(s, 0, s.len);
    }
    
    // Calculate new length
    let new_len = s.len + (new_s.len - old.len) * count;
    let size = new_len as usize + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    let src = slice::from_raw_parts(s.ptr, s.len as usize);
    
    // Build result
    let mut out_pos = 0;
    let mut in_pos = 0;
    while in_pos < s.len {
        if in_pos <= s.len - old.len {
            let check = ForgeString {
                ptr: s.ptr.add(in_pos as usize),
                len: old.len,
                is_heap: false,
            };
            if forge_string_eq(check, old) {
                // Copy replacement
                std::ptr::copy_nonoverlapping(new_s.ptr, data_ptr.add(out_pos as usize), new_s.len as usize);
                out_pos += new_s.len;
                in_pos += old.len;
                continue;
            }
        }
        *data_ptr.add(out_pos as usize) = src[in_pos as usize];
        out_pos += 1;
        in_pos += 1;
    }
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = new_len;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Get single character at index as new string
#[no_mangle]
pub unsafe extern "C" fn forge_string_char_at(s: ForgeString, index: i64) -> ForgeString {
    if index < 0 || index >= s.len {
        return EMPTY_STRING;
    }
    
    let size = 1 + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    *data_ptr = *s.ptr.add(index as usize);
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = 1;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Create string from single character code
#[no_mangle]
pub unsafe extern "C" fn forge_chr(code: i64) -> ForgeString {
    let byte = (code & 0xFF) as u8;
    
    let size = 1 + std::mem::size_of::<ForgeString>();
    let mem = forge_rc_alloc(size, TypeTag::String as u32);
    
    let data_ptr = mem.add(std::mem::size_of::<ForgeString>());
    *data_ptr = byte;
    
    let str_ptr = mem as *mut ForgeString;
    (*str_ptr).ptr = data_ptr;
    (*str_ptr).len = 1;
    (*str_ptr).is_heap = true;
    
    *str_ptr
}

/// Get character code at index (or -1 if out of bounds)
#[no_mangle]
pub extern "C" fn forge_ord(s: ForgeString, index: i64) -> i64 {
    if index < 0 || index >= s.len {
        return -1;
    }
    unsafe {
        *s.ptr.add(index as usize) as i64
    }
}
