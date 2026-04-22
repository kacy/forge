use crate::collections::list::{forge_list_new, forge_list_push_value};
use crate::string;

pub(crate) fn forge_strdup_string(text: &str) -> *mut i8 {
    let owned = format!("{}\0", text);
    unsafe { forge_strdup(owned.as_ptr() as *const i8) }
}

const FORGE_CLOSURE_ENV_SLOTS: usize = 16;

struct ForgeClosure {
    func_ptr: i64,
    env: [i64; FORGE_CLOSURE_ENV_SLOTS],
}

unsafe fn forge_closure_mut<'a>(handle: i64) -> Option<&'a mut ForgeClosure> {
    if handle == 0 {
        return None;
    }
    Some(&mut *(handle as *mut ForgeClosure))
}

unsafe fn forge_closure_ref<'a>(handle: i64) -> Option<&'a ForgeClosure> {
    if handle == 0 {
        return None;
    }
    Some(&*(handle as *const ForgeClosure))
}

#[no_mangle]
pub extern "C" fn forge_closure_new(func_ptr: i64) -> i64 {
    Box::into_raw(Box::new(ForgeClosure {
        func_ptr,
        env: [0; FORGE_CLOSURE_ENV_SLOTS],
    })) as i64
}

#[no_mangle]
pub unsafe extern "C" fn forge_closure_get_fn(handle: i64) -> i64 {
    if let Some(closure) = forge_closure_ref(handle) {
        closure.func_ptr
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_closure_set_env(handle: i64, slot: i64, value: i64) {
    if slot < 0 || (slot as usize) >= FORGE_CLOSURE_ENV_SLOTS {
        return;
    }
    if let Some(closure) = forge_closure_mut(handle) {
        closure.env[slot as usize] = value;
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_closure_get_env(handle: i64, slot: i64) -> i64 {
    if slot < 0 || (slot as usize) >= FORGE_CLOSURE_ENV_SLOTS {
        return 0;
    }
    if let Some(closure) = forge_closure_ref(handle) {
        closure.env[slot as usize]
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_print(s: string::ForgeString) {
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

#[no_mangle]
pub extern "C" fn forge_print_int(n: i64) {
    println!("{}", n);
}

#[no_mangle]
pub unsafe extern "C" fn forge_concat_cstr(a: *const i8, b: *const i8) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    if a.is_null() {
        return if b.is_null() {
            std::ptr::null_mut()
        } else {
            forge_strdup(b)
        };
    }
    if b.is_null() {
        return forge_strdup(a);
    }

    let len_a = string::forge_cstring_len(a) as usize;
    let len_b = string::forge_cstring_len(b) as usize;
    let total_len = len_a + len_b;
    let layout = Layout::from_size_align(total_len + 1, 1).unwrap();
    let result = alloc(layout) as *mut i8;

    if result.is_null() {
        return std::ptr::null_mut();
    }

    std::ptr::copy_nonoverlapping(a, result, len_a);
    std::ptr::copy_nonoverlapping(b, result.add(len_a), len_b);
    *result.add(total_len) = 0;
    result
}

#[no_mangle]
pub unsafe extern "C" fn forge_strdup(ptr: *const i8) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    if ptr.is_null() {
        return std::ptr::null_mut();
    }

    let len = string::forge_cstring_len(ptr) as usize;
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let result = alloc(layout) as *mut i8;

    if !result.is_null() {
        std::ptr::copy_nonoverlapping(ptr, result, len + 1);
    }

    result
}

#[no_mangle]
pub unsafe extern "C" fn forge_print_cstr(ptr: *const i8) {
    if ptr.is_null() {
        println!();
        return;
    }

    let len = string::forge_cstring_len(ptr) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    if let Ok(str_ref) = std::str::from_utf8(slice) {
        println!("{}", str_ref);
    } else {
        println!();
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_print_err(ptr: *const i8) {
    if ptr.is_null() {
        eprintln!();
        return;
    }

    let len = string::forge_cstring_len(ptr) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    if let Ok(str_ref) = std::str::from_utf8(slice) {
        eprintln!("{}", str_ref);
    } else {
        eprintln!();
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_eq(a: *const i8, b: *const i8) -> i64 {
    if a.is_null() && b.is_null() {
        return 1;
    }
    if a.is_null() || b.is_null() {
        return 0;
    }
    if std::ptr::eq(a, b) {
        return 1;
    }

    let mut pa = a;
    let mut pb = b;
    loop {
        let ca = *pa;
        let cb = *pb;

        if ca != cb {
            return 0;
        }

        if ca == 0 {
            return 1;
        }

        pa = pa.add(1);
        pb = pb.add(1);
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_ord_cstr(s: *const i8) -> i64 {
    if s.is_null() || *s == 0 {
        return 0;
    }
    *s as i64
}

#[no_mangle]
pub unsafe extern "C" fn forge_chr_cstr(n: i64) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let layout = Layout::from_size_align(2, 1).unwrap();
    let ptr = alloc(layout) as *mut i8;

    if !ptr.is_null() {
        *ptr = (n as u8) as i8;
        *ptr.add(1) = 0;
    }

    ptr
}

static TEST_FAILED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[no_mangle]
pub extern "C" fn forge_assert(cond: i64) {
    if cond == 0 {
        TEST_FAILED.store(true, std::sync::atomic::Ordering::Relaxed);
        eprintln!("Assertion failed");
    }
}

#[no_mangle]
pub extern "C" fn forge_assert_eq(a: i64, b: i64) {
    if a != b {
        TEST_FAILED.store(true, std::sync::atomic::Ordering::Relaxed);
        eprintln!("Assertion failed: {} != {}", a, b);
    }
}

#[no_mangle]
pub extern "C" fn forge_assert_ne(a: i64, b: i64) {
    if a == b {
        TEST_FAILED.store(true, std::sync::atomic::Ordering::Relaxed);
        eprintln!("Assertion failed: {} == {}", a, b);
    }
}

#[no_mangle]
pub extern "C" fn forge_bit_and(a: i64, b: i64) -> i64 { a & b }

#[no_mangle]
pub extern "C" fn forge_bit_or(a: i64, b: i64) -> i64 { a | b }

#[no_mangle]
pub extern "C" fn forge_bit_xor(a: i64, b: i64) -> i64 { a ^ b }

#[no_mangle]
pub extern "C" fn forge_bit_not(a: i64) -> i64 { !a }

#[no_mangle]
pub extern "C" fn forge_bit_shl(a: i64, b: i64) -> i64 { a << b }

#[no_mangle]
pub extern "C" fn forge_bit_shr(a: i64, b: i64) -> i64 { ((a as u64) >> b) as i64 }

#[no_mangle]
pub extern "C" fn forge_uint(n: i64) -> i64 { n }

#[no_mangle]
pub extern "C" fn forge_int8(n: i64) -> i64 { (n as i8) as i64 }

#[no_mangle]
pub extern "C" fn forge_int16(n: i64) -> i64 { (n as i16) as i64 }

#[no_mangle]
pub extern "C" fn forge_int32(n: i64) -> i64 { (n as i32) as i64 }

#[no_mangle]
pub extern "C" fn forge_int64(n: i64) -> i64 { n }

#[no_mangle]
pub extern "C" fn forge_uint8(n: i64) -> i64 { (n as u8) as i64 }

#[no_mangle]
pub extern "C" fn forge_uint16(n: i64) -> i64 { (n as u16) as i64 }

#[no_mangle]
pub extern "C" fn forge_uint32(n: i64) -> i64 { (n as u32) as i64 }

#[no_mangle]
pub extern "C" fn forge_uint64(n: i64) -> i64 { n }

#[no_mangle]
pub extern "C" fn forge_abs(n: i64) -> i64 { n.abs() }

#[no_mangle]
pub extern "C" fn forge_min(a: i64, b: i64) -> i64 {
    if a < b { a } else { b }
}

#[no_mangle]
pub extern "C" fn forge_max(a: i64, b: i64) -> i64 {
    if a > b { a } else { b }
}

#[no_mangle]
pub extern "C" fn forge_clamp(n: i64, min: i64, max: i64) -> i64 {
    if n < min {
        min
    } else if n > max {
        max
    } else {
        n
    }
}

#[no_mangle]
pub extern "C" fn forge_pow(a: f64, b: f64) -> f64 { a.powf(b) }

#[no_mangle]
pub extern "C" fn forge_sqrt(n: f64) -> f64 { n.sqrt() }

#[no_mangle]
pub extern "C" fn forge_floor(n: f64) -> f64 { n.floor() }

#[no_mangle]
pub extern "C" fn forge_ceil(n: f64) -> f64 { n.ceil() }

#[no_mangle]
pub extern "C" fn forge_round(n: f64) -> f64 { n.round() }

#[no_mangle]
pub extern "C" fn forge_sin(n: f64) -> f64 { n.sin() }

#[no_mangle]
pub extern "C" fn forge_cos(n: f64) -> f64 { n.cos() }

#[no_mangle]
pub extern "C" fn forge_tan(n: f64) -> f64 { n.tan() }

#[no_mangle]
pub extern "C" fn forge_asin(n: f64) -> f64 { n.asin() }

#[no_mangle]
pub extern "C" fn forge_acos(n: f64) -> f64 { n.acos() }

#[no_mangle]
pub extern "C" fn forge_atan(n: f64) -> f64 { n.atan() }

#[no_mangle]
pub extern "C" fn forge_atan2(y: f64, x: f64) -> f64 { y.atan2(x) }

#[no_mangle]
pub extern "C" fn forge_log(n: f64) -> f64 { n.ln() }

#[no_mangle]
pub extern "C" fn forge_log10(n: f64) -> f64 { n.log10() }

#[no_mangle]
pub extern "C" fn forge_log2(n: f64) -> f64 { n.log2() }

#[no_mangle]
pub extern "C" fn forge_exp(n: f64) -> f64 { n.exp() }

#[no_mangle]
pub extern "C" fn forge_abs_float(n: f64) -> f64 { n.abs() }

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_compare(a: *const i8, b: *const i8) -> i64 {
    if a.is_null() && b.is_null() { return 0; }
    if a.is_null() { return -1; }
    if b.is_null() { return 1; }
    let mut pa = a;
    let mut pb = b;
    loop {
        let ca = *pa as u8;
        let cb = *pb as u8;
        if ca != cb {
            return if ca < cb { -1 } else { 1 };
        }
        if ca == 0 {
            return 0;
        }
        pa = pa.add(1);
        pb = pb.add(1);
    }
}

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_lt(a: *const i8, b: *const i8) -> i64 {
    if forge_cstring_compare(a, b) < 0 { 1 } else { 0 }
}

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_gt(a: *const i8, b: *const i8) -> i64 {
    if forge_cstring_compare(a, b) > 0 { 1 } else { 0 }
}

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_lte(a: *const i8, b: *const i8) -> i64 {
    if forge_cstring_compare(a, b) <= 0 { 1 } else { 0 }
}

#[no_mangle]
pub unsafe extern "C" fn forge_cstring_gte(a: *const i8, b: *const i8) -> i64 {
    if forge_cstring_compare(a, b) >= 0 { 1 } else { 0 }
}

#[no_mangle]
pub unsafe extern "C" fn forge_int_to_cstr(n: i64) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let s = n.to_string();
    let len = s.len();
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let ptr = alloc(layout) as *mut i8;

    if !ptr.is_null() {
        std::ptr::copy_nonoverlapping(s.as_ptr(), ptr as *mut u8, len);
        *ptr.add(len) = 0;
    }

    ptr
}

#[no_mangle]
pub unsafe extern "C" fn forge_uint_to_cstr(n: i64) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let s = (n as u64).to_string();
    let len = s.len();
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let ptr = alloc(layout) as *mut i8;

    if !ptr.is_null() {
        std::ptr::copy_nonoverlapping(s.as_ptr(), ptr as *mut u8, len);
        *ptr.add(len) = 0;
    }

    ptr
}

#[no_mangle]
pub extern "C" fn forge_float_to_cstr(n: f64) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let s = if n == n.floor() && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        let formatted = format!("{:.6}", n);
        formatted.trim_end_matches('0').trim_end_matches('.').to_string()
    };
    let len = s.len();
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let ptr = unsafe { alloc(layout) as *mut i8 };

    if !ptr.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), ptr as *mut u8, len);
            *ptr.add(len) = 0;
        }
    }

    ptr
}

#[no_mangle]
pub extern "C" fn forge_bool_to_cstr(b: i64) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let s = if b != 0 { "true" } else { "false" };
    let len = s.len();
    let layout = Layout::from_size_align(len + 1, 1).unwrap();
    let ptr = unsafe { alloc(layout) as *mut i8 };

    if !ptr.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), ptr as *mut u8, len);
            *ptr.add(len) = 0;
        }
    }

    ptr
}

pub use forge_ceil as forge_math_ceil;
pub use forge_floor as forge_math_floor;
pub use forge_pow as forge_math_pow;
pub use forge_round as forge_math_round;
pub use forge_sqrt as forge_math_sqrt;

#[no_mangle]
pub unsafe extern "C" fn forge_free(ptr: *mut i8) {
    use std::alloc::Layout;

    if !ptr.is_null() {
        std::alloc::dealloc(ptr as *mut u8, Layout::new::<u8>());
    }
}

#[no_mangle]
pub extern "C" fn forge_int_to_float(n: i64) -> f64 { n as f64 }

#[no_mangle]
pub extern "C" fn forge_float_to_int(n: f64) -> i64 { n as i64 }

pub(crate) unsafe fn forge_cstring_empty() -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let layout = Layout::from_size_align(1, 1).unwrap();
    let ptr = alloc(layout) as *mut i8;
    if !ptr.is_null() {
        *ptr = 0;
    }
    ptr
}

pub(crate) unsafe fn forge_copy_bytes_to_cstring(bytes: &[u8]) -> *mut i8 {
    use std::alloc::{alloc, Layout};

    let layout = Layout::from_size_align(bytes.len() + 1, 1).unwrap();
    let ptr = alloc(layout) as *mut i8;
    if !ptr.is_null() {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
        *ptr.add(bytes.len()) = 0;
    }
    ptr
}

#[no_mangle]
pub extern "C" fn forge_second(_a: i64, b: i64) -> i64 { b }

#[no_mangle]
pub unsafe extern "C" fn forge_struct_alloc(num_fields: i64) -> i64 {
    use std::alloc::{alloc_zeroed, Layout};

    let size = (num_fields.max(0) as usize) * 8;
    if size == 0 {
        return 0;
    }

    let layout = Layout::from_size_align(size, 8).unwrap();
    let ptr = alloc_zeroed(layout);
    if ptr.is_null() {
        return 0;
    }
    ptr as i64
}

#[no_mangle]
pub unsafe extern "C" fn forge_args_to_list() -> i64 {
    use std::alloc::{alloc, Layout};

    let list = forge_list_new(8, 0);

    for arg in std::env::args() {
        let arg_len = arg.len();
        let arg_layout = Layout::from_size_align(arg_len + 1, 1).unwrap();
        let arg_ptr = alloc(arg_layout) as *mut i8;

        if !arg_ptr.is_null() {
            std::ptr::copy_nonoverlapping(arg.as_ptr(), arg_ptr as *mut u8, arg_len);
            *arg_ptr.add(arg_len) = 0;
            forge_list_push_value(list, arg_ptr as i64);
        }
    }

    list.ptr as i64
}
