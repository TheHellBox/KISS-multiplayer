#[cfg(windows)]
fn main() {
    if std::env::var("CARGO_FEATURE_BUILD_ICON").is_ok() {
        let mut res = winres::WindowsResource::new();
        res.set_icon("../assets/icon/server_icon.ico");
        res.compile().unwrap();
    }
}

#[cfg(not(windows))]
fn main() {}