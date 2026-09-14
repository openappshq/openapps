fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("native/macos.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .flag("-mmacosx-version-min=14.0")
            .compile("openklack_macos");
        for framework in [
            "AppKit",
            "ApplicationServices",
            "Carbon",
            "CoreAudio",
            "IOKit",
        ] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rerun-if-changed=native/macos.m");
    }
    if std::env::var_os("CARGO_FEATURE_LICENSING").is_some() {
        licensing_config();
    }
    tauri_build::build();
}

/// Official builds compile the Dodo host, the paid product ID and the trial registry in from the
/// environment. Missing or malformed values stop the build instead of shipping an app that can
/// never activate.
fn licensing_config() {
    const VARIABLES: [(&str, &str); 3] = [
        ("OPENKLACK_LICENSE_ENV", "test or live"),
        ("OPENKLACK_DODO_PAID_PRODUCT_ID", "the OpenKlack product ID"),
        (
            "OPENKLACK_BUY_URL",
            "the https checkout link for the paid product",
        ),
    ];
    for (name, _) in VARIABLES {
        println!("cargo:rerun-if-env-changed={name}");
    }
    let mut missing = Vec::new();
    let mut values = std::collections::HashMap::new();
    for (name, meaning) in VARIABLES {
        match std::env::var(name) {
            Ok(value) if !value.trim().is_empty() && !value.contains(char::is_whitespace) => {
                values.insert(name, value);
            }
            _ => missing.push(format!("  {name}: {meaning}")),
        }
    }
    if !missing.is_empty() {
        panic!(
            "The `licensing` feature needs build-time configuration. Set:\n{}\nBuild without `--features licensing` for an unrestricted source build.",
            missing.join("\n")
        );
    }
    let environment = values["OPENKLACK_LICENSE_ENV"].clone();
    let host = match environment.as_str() {
        "live" => "https://live.dodopayments.com",
        "test" => "https://test.dodopayments.com",
        other => panic!("OPENKLACK_LICENSE_ENV must be `test` or `live`, not `{other}`."),
    };
    if !values["OPENKLACK_BUY_URL"].starts_with("https://") {
        panic!("OPENKLACK_BUY_URL must be an https:// link.");
    }
    println!("cargo:rustc-env=OPENKLACK_DODO_HOST={host}");
    for (name, value) in values {
        println!("cargo:rustc-env={name}={value}");
    }
    println!("cargo:rerun-if-env-changed=OPENKLACK_SUPPORT_URL");
    let support = std::env::var("OPENKLACK_SUPPORT_URL")
        .ok()
        .filter(|value| value.starts_with("https://") && !value.contains(char::is_whitespace))
        .unwrap_or_else(|| "https://openapps.space/OpenKlack/".into());
    println!("cargo:rustc-env=OPENKLACK_SUPPORT_URL={support}");
    println!(
        "cargo:rustc-env=OPENKLACK_TRIAL_REGISTRY_URL={}",
        trial_registry(&environment)
    );
}

/// The trial registry's origin. Defaults to the production registry for both environments (the
/// request's `env` keeps them apart); a test build may point at a local registry over plain HTTP.
fn trial_registry(environment: &str) -> String {
    const NAME: &str = "OPENKLACK_TRIAL_REGISTRY_URL";
    println!("cargo:rerun-if-env-changed={NAME}");
    let origin = std::env::var(NAME)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "https://openapps.space".into());
    let origin = origin.trim().trim_end_matches('/').to_string();
    if origin.contains(|c: char| c.is_whitespace() || matches!(c, '?' | '#')) {
        panic!("{NAME} must be an origin such as https://openapps.space, not `{origin}`.");
    }
    let local = origin.strip_prefix("http://").is_some_and(|rest| {
        let (address, port) = rest.split_once(':').unwrap_or((rest, "0"));
        matches!(address, "127.0.0.1" | "localhost")
            && !port.is_empty()
            && port.bytes().all(|b| b.is_ascii_digit())
    });
    let secure = origin.len() > "https://".len() && origin.starts_with("https://");
    match (secure, local, environment) {
        (true, _, _) | (false, true, "test") => origin,
        (false, true, _) => panic!("A live build must reach {NAME} over https://."),
        _ => panic!(
            "{NAME} must be https://…, or http://127.0.0.1:<port> for a test build, not `{origin}`."
        ),
    }
}
