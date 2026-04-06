use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(forge_cranelift_new_api)");

    let Some(lockfile) = workspace_lockfile() else {
        return;
    };
    let Ok(contents) = fs::read_to_string(&lockfile) else {
        return;
    };
    if uses_new_cranelift_api(&contents) {
        println!("cargo:rustc-cfg=forge_cranelift_new_api");
    }
}

fn workspace_lockfile() -> Option<PathBuf> {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").ok()?);
    for ancestor in out_dir.ancestors() {
        if ancestor.file_name().and_then(|name| name.to_str()) == Some("target") {
            let lockfile = ancestor.parent()?.join("Cargo.lock");
            if lockfile.exists() {
                return Some(lockfile);
            }
        }
    }
    None
}

fn uses_new_cranelift_api(lockfile: &str) -> bool {
    let mut in_frontend = false;
    for line in lockfile.lines() {
        let trimmed = line.trim();
        if trimmed == "[[package]]" {
            in_frontend = false;
            continue;
        }
        if trimmed == "name = \"cranelift-frontend\"" {
            in_frontend = true;
            continue;
        }
        if in_frontend && trimmed.starts_with("version = ") {
            let version = trimmed.trim_start_matches("version = ").trim_matches('"');
            return version_is_new_api(version);
        }
    }
    false
}

fn version_is_new_api(version: &str) -> bool {
    let mut parts = version.split('.');
    let major = parts.next().and_then(|part| part.parse::<u32>().ok()).unwrap_or(0);
    let minor = parts.next().and_then(|part| part.parse::<u32>().ok()).unwrap_or(0);
    major > 0 || minor >= 130
}
