//! Update decisions that never touch the network or the app: the automatic check schedule and
//! reading a signed feed.

use super::Settings;
use base64::Engine;
use semver::Version;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const FEED_URL: &str = "https://openapps.space/updates/openklack/latest.json";
pub const RELEASE_DOWNLOADS: &str = "https://github.com/openappshq/openapps/releases/download/";
pub const HOUR: i64 = 60 * 60;
pub const DAY: i64 = 24 * HOUR;
pub const MAX_FEED_BYTES: usize = 64 * 1024;
pub const MAX_FEED_SIGNATURE_BYTES: usize = 4 * 1024;
const MAX_NOTES_CHARS: usize = 16_000;

pub const INVALID_SIGNATURE: &str =
    "The update signature could not be verified. Nothing was installed.";
pub const INVALID_FEED: &str = "The update server returned an invalid release. Try again later.";
pub const FOREIGN_DOWNLOAD: &str =
    "The update points outside OpenKlack’s official releases. Nothing was installed.";
pub const NOT_FOR_THIS_MAC: &str = "This release does not include an update for your Mac.";

/// When checks happened, so a restart neither re-checks early nor forgets a failure's backoff.
/// Times are Unix seconds from the wall clock.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct History {
    pub last_success_at: Option<i64>,
    pub last_attempt_at: Option<i64>,
    pub failures: u32,
}

impl History {
    pub fn succeeded(&mut self, now: i64) {
        self.last_success_at = Some(now);
        self.last_attempt_at = Some(now);
        self.failures = 0;
    }

    pub fn failed(&mut self, now: i64) {
        self.last_attempt_at = Some(now);
        self.failures = self.failures.saturating_add(1);
    }
}

/// `updates.json` in the app's data folder. A missing or unreadable file is the default: every
/// automatic behaviour off.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Saved {
    pub settings: Settings,
    pub history: History,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trigger {
    Launch,
    Timer,
}

/// Whether an automatic check should run now. Nothing runs unless the user turned automatic
/// checks on. Then: at launch, when the last successful check is a day old (the timer also
/// catches up after sleep), and after a failure only once its backoff (an hour, then a day) has
/// passed. A clock set before the last attempt counts as due, so a wrong clock can't stop checks;
/// the attempt then moves the reference to the new clock, so it can't loop either.
pub fn automatic_check_due(saved: &Saved, now: i64, trigger: Trigger) -> bool {
    if !saved.settings.check_automatically {
        return false;
    }
    let history = saved.history;
    if history.failures > 0
        && let Some(last) = history.last_attempt_at
    {
        let wait = if history.failures == 1 { HOUR } else { DAY };
        return now < last || now >= last + wait;
    }
    match (trigger, history.last_success_at) {
        (Trigger::Launch, _) | (_, None) => true,
        (Trigger::Timer, Some(last)) => now < last || now >= last + DAY,
    }
}

#[derive(Deserialize)]
struct Feed {
    app: String,
    channel: String,
    version: String,
    #[serde(default)]
    notes: Option<String>,
    published_at: String,
    #[serde(default)]
    minimum_macos: Option<String>,
    url: String,
    sha256: String,
    signature: String,
    #[serde(default)]
    platforms: HashMap<String, Platform>,
}

#[derive(Deserialize)]
struct Platform {
    url: String,
    signature: String,
}

/// A verified newer release for this Mac.
#[derive(Clone, Debug, PartialEq)]
pub struct Offer {
    pub version: Version,
    pub notes: Option<String>,
    pub archive_url: String,
    pub archive_signature: String,
    /// The verified feed, which the updater plugin's own response must equal.
    pub json: serde_json::Value,
}

pub struct Source<'a> {
    pub public_key: &'a str,
    /// Release downloads, ending in `/`; the feed must name `<downloads>openklack-v<version>/…`.
    pub downloads: &'a str,
    /// `aarch64` or `x86_64`, as the updater plugin names it.
    pub arch: &'a str,
    pub macos: Option<Version>,
}

/// Verifies the feed's detached signature over its exact bytes, then trusts its fields: the app,
/// the channel, a strict version, downloads under this app's release tag, and an update archive
/// for this Mac. `Ok(None)` means there is nothing newer to install (never a downgrade).
pub fn read_feed(
    bytes: &[u8],
    signature: &[u8],
    source: &Source,
    current: &Version,
) -> Result<Option<Offer>, String> {
    if bytes.len() > MAX_FEED_BYTES || signature.len() > MAX_FEED_SIGNATURE_BYTES {
        return Err(INVALID_FEED.into());
    }
    let signature = std::str::from_utf8(signature).map_err(|_| INVALID_SIGNATURE)?;
    verify(bytes, signature, source.public_key)?;
    let json: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| INVALID_FEED)?;
    let feed: Feed = serde_json::from_value(json.clone()).map_err(|_| INVALID_FEED)?;
    let version = Version::parse(&feed.version).map_err(|_| INVALID_FEED)?;
    if feed.app != "openklack"
        || feed.channel != "stable"
        || feed.published_at.trim().is_empty()
        || feed.sha256.len() != 64
        || !feed.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        || feed.signature.trim().is_empty()
    {
        return Err(INVALID_FEED.into());
    }
    let base = format!(
        "{}openklack-v{version}/OpenKlack-{version}",
        source.downloads
    );
    if feed.url != format!("{base}.zip") {
        return Err(FOREIGN_DOWNLOAD.into());
    }
    let archive = feed
        .platforms
        .get(&format!("darwin-{}", source.arch))
        .ok_or(NOT_FOR_THIS_MAC)?;
    if archive.url != format!("{base}.app.tar.gz") {
        return Err(FOREIGN_DOWNLOAD.into());
    }
    decode_signature(&archive.signature)?;
    if version <= *current {
        return Ok(None);
    }
    if let (Some(minimum), Some(macos)) = (&feed.minimum_macos, &source.macos)
        && macos_version(minimum).ok_or(INVALID_FEED)? > *macos
    {
        return Ok(None);
    }
    Ok(Some(Offer {
        version,
        notes: feed
            .notes
            .map(|notes| notes.chars().take(MAX_NOTES_CHARS).collect()),
        archive_url: archive.url.clone(),
        archive_signature: archive.signature.clone(),
        json,
    }))
}

/// `14`, `14.5` or `14.5.1` as a version.
pub fn macos_version(value: &str) -> Option<Version> {
    let mut parts = value.trim().split('.').map(|part| part.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().unwrap_or(Some(0))?;
    let patch = parts.next().unwrap_or(Some(0))?;
    parts
        .next()
        .is_none()
        .then(|| Version::new(major, minor, patch))
}

fn base64_text(value: &str) -> Option<String> {
    base64::engine::general_purpose::STANDARD
        .decode(value.trim())
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
}

fn decode_signature(signature: &str) -> Result<minisign_verify::Signature, String> {
    base64_text(signature)
        .and_then(|text| minisign_verify::Signature::decode(&text).ok())
        .ok_or_else(|| INVALID_SIGNATURE.into())
}

/// Checks a Tauri updater signature (base64 of a minisign signature file) over `data` with a
/// Tauri updater public key (base64 of a minisign public key file). Only prehashed signatures,
/// which is what `tauri signer sign` writes, are accepted.
pub fn verify(data: &[u8], signature: &str, public_key: &str) -> Result<(), String> {
    let key = base64_text(public_key)
        .and_then(|text| minisign_verify::PublicKey::decode(&text).ok())
        .ok_or("This build’s update key is invalid.")?;
    key.verify(data, &decode_signature(signature)?, false)
        .map_err(|_| INVALID_SIGNATURE.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Throwaway key pair generated with `tauri signer generate`; only the public half is kept.
    const KEY: &str = include_str!("../../../fixtures/updates/key.pub");
    const FEED: &[u8] = include_bytes!("../../../fixtures/updates/latest.json");
    const FEED_SIGNATURE: &[u8] = include_bytes!("../../../fixtures/updates/latest.json.sig");
    const FOREIGN: &[u8] = include_bytes!("../../../fixtures/updates/foreign.json");
    const FOREIGN_SIGNATURE: &[u8] = include_bytes!("../../../fixtures/updates/foreign.json.sig");
    const OTHER_KEY: &str = include_str!("../../../fixtures/updates/other-key.pub");

    fn source(arch: &str) -> Source<'_> {
        Source {
            public_key: KEY,
            downloads: RELEASE_DOWNLOADS,
            arch,
            macos: Some(Version::new(15, 0, 0)),
        }
    }

    fn enabled(history: History) -> Saved {
        Saved {
            settings: Settings {
                check_automatically: true,
                install_automatically: false,
            },
            history,
        }
    }

    #[test]
    fn a_fresh_install_never_checks_on_its_own() {
        let fresh: Saved = serde_json::from_str("{}").unwrap();
        assert_eq!(fresh, Saved::default());
        assert!(!fresh.settings.check_automatically);
        assert!(!fresh.settings.install_automatically);
        for now in [0, HOUR, DAY, 400 * DAY] {
            for trigger in [Trigger::Launch, Trigger::Timer] {
                assert!(!automatic_check_due(&fresh, now, trigger));
            }
        }
        // Turning checks off stops them whatever the history says.
        let mut off = enabled(History::default());
        off.settings.check_automatically = false;
        assert!(!automatic_check_due(&off, 10 * DAY, Trigger::Launch));
    }

    #[test]
    fn automatic_checks_run_at_launch_daily_and_after_backoff() {
        let now = 1_000 * DAY;
        assert!(automatic_check_due(
            &enabled(History::default()),
            now,
            Trigger::Timer
        ));
        let mut history = History::default();
        history.succeeded(now);
        let saved = enabled(history);
        assert!(automatic_check_due(&saved, now + 60, Trigger::Launch));
        assert!(!automatic_check_due(&saved, now + DAY - 1, Trigger::Timer));
        assert!(automatic_check_due(&saved, now + DAY, Trigger::Timer));
        assert!(automatic_check_due(&saved, now - 10, Trigger::Timer));

        history.failed(now + DAY);
        let saved = enabled(history);
        assert!(!automatic_check_due(
            &saved,
            now + DAY + HOUR - 1,
            Trigger::Launch
        ));
        assert!(automatic_check_due(
            &saved,
            now + DAY + HOUR,
            Trigger::Timer
        ));
        history.failed(now + DAY + HOUR);
        let saved = enabled(history);
        assert!(!automatic_check_due(
            &saved,
            now + DAY + 2 * HOUR,
            Trigger::Timer
        ));
        assert!(automatic_check_due(
            &saved,
            now + 2 * DAY + HOUR,
            Trigger::Timer
        ));
        history.succeeded(now + 3 * DAY);
        assert_eq!(history.failures, 0);
    }

    #[test]
    fn a_signed_feed_offers_only_newer_releases_for_this_mac() {
        let offer = read_feed(
            FEED,
            FEED_SIGNATURE,
            &source("aarch64"),
            &Version::new(0, 1, 0),
        )
        .unwrap()
        .unwrap();
        assert_eq!(offer.version, Version::new(0, 2, 0));
        assert_eq!(
            offer.archive_url,
            "https://github.com/openappshq/openapps/releases/download/openklack-v0.2.0/OpenKlack-0.2.0.app.tar.gz"
        );
        assert_eq!(
            offer.json,
            serde_json::from_slice::<serde_json::Value>(FEED).unwrap()
        );
        for current in [Version::new(0, 2, 0), Version::new(1, 0, 0)] {
            assert_eq!(
                read_feed(FEED, FEED_SIGNATURE, &source("aarch64"), &current).unwrap(),
                None
            );
        }
        assert_eq!(
            read_feed(
                FEED,
                FEED_SIGNATURE,
                &source("riscv64"),
                &Version::new(0, 1, 0)
            ),
            Err(NOT_FOR_THIS_MAC.into())
        );
        let mut old_mac = source("x86_64");
        old_mac.macos = Some(Version::new(13, 6, 0));
        assert_eq!(
            read_feed(FEED, FEED_SIGNATURE, &old_mac, &Version::new(0, 1, 0)),
            Ok(None)
        );
    }

    #[test]
    fn a_feed_is_trusted_only_with_a_valid_signature_and_official_downloads() {
        let current = Version::new(0, 1, 0);
        let mut tampered = FEED.to_vec();
        let at = tampered.iter().position(|b| *b == b'2').unwrap();
        tampered[at] = b'9';
        assert_eq!(
            read_feed(&tampered, FEED_SIGNATURE, &source("aarch64"), &current),
            Err(INVALID_SIGNATURE.into())
        );
        let mut other = source("aarch64");
        other.public_key = OTHER_KEY;
        assert_eq!(
            read_feed(FEED, FEED_SIGNATURE, &other, &current),
            Err(INVALID_SIGNATURE.into())
        );
        assert_eq!(
            read_feed(FEED, b"not a signature", &source("aarch64"), &current),
            Err(INVALID_SIGNATURE.into())
        );
        // Correctly signed, but pointing at another download location.
        assert_eq!(
            read_feed(FOREIGN, FOREIGN_SIGNATURE, &source("aarch64"), &current),
            Err(FOREIGN_DOWNLOAD.into())
        );
        let oversized = vec![b' '; MAX_FEED_BYTES + 1];
        assert_eq!(
            read_feed(&oversized, FEED_SIGNATURE, &source("aarch64"), &current),
            Err(INVALID_FEED.into())
        );
    }

    #[test]
    fn macos_versions_parse_like_the_feed_writes_them() {
        assert_eq!(macos_version("14.0"), Some(Version::new(14, 0, 0)));
        assert_eq!(macos_version("15"), Some(Version::new(15, 0, 0)));
        assert_eq!(macos_version("15.5.1"), Some(Version::new(15, 5, 1)));
        assert_eq!(macos_version("15.x"), None);
        assert_eq!(macos_version("1.2.3.4"), None);
    }
}
