fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    if target_os == "linux" && target_arch == "x86_64" {
        cc::Build::new()
            .file("compat.c")
            .compile("vieneu_compat");
        println!("cargo:rustc-link-arg=-Wl,--wrap=log10f");
    }
}
