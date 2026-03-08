//! Forge Runtime - Core runtime library for the Forge language
//!
//! This crate provides the runtime support for Forge programs:
//! - Reference counting (ARC) with cycle collection
//! - String operations
//! - Collections (List, Map, Set)
//! - Concurrency primitives
//!
//! The runtime is designed to be called from Cranelift-generated code
//! via a C-compatible FFI boundary.

#![allow(clippy::missing_safety_doc)]

pub mod arc;
pub mod collections;
pub mod concurrency;
pub mod string;

use std::sync::atomic::AtomicUsize;

/// Global statistics for debugging
pub static ALLOCATED_BYTES: AtomicUsize = AtomicUsize::new(0);
pub static LIVE_OBJECTS: AtomicUsize = AtomicUsize::new(0);

/// Initialize the runtime
/// 
/// # Safety
/// Must be called before any other runtime functions
#[no_mangle]
pub unsafe extern "C" fn forge_runtime_init() {
    arc::init_cycle_collector();
}

/// Clean up the runtime
/// 
/// # Safety
/// Should be called at program exit
#[no_mangle]
pub unsafe extern "C" fn forge_runtime_shutdown() {
    arc::shutdown_cycle_collector();
}

/// Print a string to stdout
/// 
/// # Safety
/// s must be a valid ForgeString
#[no_mangle]
pub unsafe extern "C" fn forge_print(s: string::ForgeString) {
    use std::io::Write;
    
    if s.ptr.is_null() || s.len == 0 {
        println!();
        return;
    }
    
    let slice = std::slice::from_raw_parts(s.ptr, s.len as usize);
    if let Ok(str_ref) = std::str::from_utf8(slice) {
        println!("{}", str_ref);
    } else {
        println!();
    }
}

/// Print an integer (for testing)
#[no_mangle]
pub extern "C" fn forge_print_int(n: i64) {
    println!("{}", n);
}

/// Simple string concatenation for two C string pointers
/// Allocates new memory for the result
/// 
/// # Safety
/// Both pointers must be valid null-terminated C strings
#[no_mangle]
pub unsafe extern "C" fn forge_concat_cstr(a: *const i8, b: *const i8) -> *mut i8 {
    use std::alloc::{alloc, Layout};
    
    if a.is_null() {
        return if b.is_null() { std::ptr::null_mut() } else { forge_strdup(b) };
    }
    if b.is_null() {
        return forge_strdup(a);
    }
    
    // Calculate lengths
    let mut len_a = 0;
    let mut p = a;
    while *p != 0 {
        len_a += 1;
        p = p.add(1);
    }
    
    let mut len_b = 0;
    let mut p = b;
    while *p != 0 {
        len_b += 1;
        p = p.add(1);
    }
    
    let total_len = len_a + len_b;
    let layout = Layout::from_size_align(total_len + 1, 1).unwrap();
    let result = alloc(layout) as *mut i8;
    
    if result.is_null() {
        return std::ptr::null_mut();
    }
    
    // Copy a
    std::ptr::copy_nonoverlapping(a, result, len_a);
    // Copy b
    std::ptr::copy_nonoverlapping(b, result.add(len_a), len_b);
    // Null terminator
    *result.add(total_len) = 0;
    
    result
}

/// Duplicate a C string
/// 
/// # Safety
/// ptr must be a valid null-terminated C string
#[no_mangle]
pub unsafe extern "C" fn forge_strdup(ptr: *const i8) -> *mut i8 {
    use std::alloc::{alloc, Layout};
    
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    
    let mut len = 0;
    let mut p = ptr;
    while *p != 0 {
        len += 1;
        p = p.add(1);
    }
    
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let result = alloc(layout) as *mut i8;
    
    if !result.is_null() {
        std::ptr::copy_nonoverlapping(ptr, result, len + 1);
    }
    
    result
}

/// Print a C string (null-terminated)
/// 
/// # Safety
/// ptr must be a valid null-terminated C string
#[no_mangle]
pub unsafe extern "C" fn forge_print_cstr(ptr: *const i8) {
    if ptr.is_null() {
        println!();
        return;
    }
    
    // Calculate length
    let mut len = 0;
    let mut p = ptr;
    while *p != 0 {
        len += 1;
        p = p.add(1);
    }
    
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    if let Ok(str_ref) = std::str::from_utf8(slice) {
        println!("{}", str_ref);
    } else {
        println!();
    }
}

/// Bitwise AND
#[no_mangle]
pub extern "C" fn forge_bit_and(a: i64, b: i64) -> i64 {
    a & b
}

/// Bitwise OR
#[no_mangle]
pub extern "C" fn forge_bit_or(a: i64, b: i64) -> i64 {
    a | b
}

/// Bitwise XOR
#[no_mangle]
pub extern "C" fn forge_bit_xor(a: i64, b: i64) -> i64 {
    a ^ b
}

/// Bitwise NOT
#[no_mangle]
pub extern "C" fn forge_bit_not(a: i64) -> i64 {
    !a
}

/// Bitwise shift left
#[no_mangle]
pub extern "C" fn forge_bit_shl(a: i64, b: i64) -> i64 {
    a << b
}

/// Bitwise shift right (arithmetic)
#[no_mangle]
pub extern "C" fn forge_bit_shr(a: i64, b: i64) -> i64 {
    a >> b
}
