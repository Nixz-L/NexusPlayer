pub fn get_nexus_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
