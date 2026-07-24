use std::{env, path::PathBuf};

fn main() {
    let header = PathBuf::from("../../abi/kadath_scheduler.h");
    println!("cargo:rerun-if-changed={}", header.display());
    println!("cargo:rerun-if-changed=../../abi/kadath_errors.h");

    // 本机 Windows 开发环境未把 LLVM 加入 PATH，沿用 World crate 的保守回退。
    if cfg!(windows) && env::var_os("LIBCLANG_PATH").is_none() {
        let llvm_bin = PathBuf::from(r"C:\Program Files\LLVM\bin");
        if llvm_bin.join("libclang.dll").exists() {
            env::set_var("LIBCLANG_PATH", llvm_bin);
        }
    }

    let bindings = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .clang_arg("-I../../abi")
        .allowlist_type("kadath_scheduler_.*")
        .allowlist_var("KADATH_.*")
        .allowlist_function("kadath_scheduler_.*")
        .derive_default(true)
        .generate()
        .expect("failed to generate kadath_scheduler C ABI bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR must be set"));
    bindings
        .write_to_file(out_path.join("kadath_scheduler_bindings.rs"))
        .expect("failed to write kadath_scheduler bindings");
}
