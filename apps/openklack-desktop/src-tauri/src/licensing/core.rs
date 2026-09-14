//! The licensing rules from LICENSING.md, with no clock, network or Keychain of their own.
//! Time is passed in by the caller as a `Moment`: the wall clock in Unix seconds, plus a
//! monotonic clock that keeps counting through sleep. Dodo and the trial registry are traits so
//! tests script every answer.

use serde::{Deserialize, Serialize};

pub const DAY: i64 = 86_400;
pub const CHECK_INTERVAL: i64 = DAY;
pub const GRACE_PERIOD: i64 = 7 * DAY;
pub const GRACE_WARNING_AFTER: i64 = 5 * DAY;
pub const TRIAL_LENGTH: i64 = 3 * DAY;
/// How long a trial the registry has not answered for may run.
pub const TRIAL_OFFLINE_LIMIT: i64 = DAY;
pub const CLOCK_ROLLBACK_TOLERANCE: i64 = 3600;
pub const MIN_BACKOFF: i64 = 60;
pub const MAX_BACKOFF: i64 = 3600;
/// The longest `Retry-After` honoured; anything larger is treated as a day.
pub const MAX_HOLD: i64 = DAY;
pub const ACTIVATION_NAME: &str = "Mac";
pub const APP_NAME: &str = "OpenKlack";
/// The app id the trial registry knows this app by; it also salts the device hash.
pub const APP_ID: &str = "openklack";
const DEVICE_HASH_VERSION: &str = "openapps-trial-v1";
/// The `kind` the trial-key era wrote for a trial key's record.
const LEGACY_TRIAL_KIND: &str = "trial";

/// A point in time: the wall clock, and a monotonic clock (seconds, arbitrary origin) that keeps
/// counting through sleep and ignores changes to the wall clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Moment {
    pub wall: i64,
    pub mono: i64,
}

impl From<i64> for Moment {
    /// A moment whose monotonic clock moves with the wall clock.
    fn from(wall: i64) -> Self {
        Self { wall, mono: wall }
    }
}

/// The Keychain record for one activation of this Mac.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub license_key: String,
    pub instance_id: String,
    pub product_id: String,
    /// Written only by the trial-key era: `trial` marks a retired trial key's record, which is
    /// never a license.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Activation `created_at`, server time.
    pub activated_at: i64,
    /// Time of the last `valid: true` or activation, from the response `Date` header.
    pub last_success_at: i64,
    /// The local clock at that moment. Time since then is measured from here and added to the
    /// server's time, so the local clock only ever adds elapsed time.
    #[serde(default)]
    pub last_success_local: i64,
    /// The latest moment seen: the server's `Date` on a successful check, otherwise the clock
    /// as anchored above, raised every tick and never lowered by the clock. A clock earlier
    /// than this is not trusted until Dodo answers again.
    #[serde(default)]
    pub last_observed_at: i64,
    /// Set by `valid: false` for this activation; only a new activation clears it.
    #[serde(default)]
    pub revoked: bool,
    /// Counts authoritative changes to this activation (activation, `valid: true`, revocation,
    /// removal). The revocation journal refers to it, never to a clock.
    #[serde(default)]
    pub event_seq: u64,
}

/// Everything kept in the license Keychain item.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Stored {
    #[serde(default)]
    pub license: Option<Record>,
    /// Deactivations this Mac owes but could not deliver; retried until Dodo answers, kept
    /// across restarts and even without a record.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_cleanups: Vec<Probe>,
}

/// The trial Keychain item. Never deleted by the app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrialRecord {
    /// Trial start on the local clock: the registry's start converted to local time, or the
    /// local clock at a provisional start.
    pub started_at: i64,
    /// The latest moment the trial has reached; only ever raised. `elapsed` is measured to it.
    pub last_seen_at: i64,
    /// The trial registry has answered for this Mac.
    pub registered: bool,
    /// A random stand-in for the hardware UUID, used only when that cannot be read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
}

impl TrialRecord {
    /// A provisional trial starting at `started_at`, seen at `now`.
    pub fn provisional(started_at: i64, now: i64) -> Self {
        Self {
            started_at: started_at.min(now),
            last_seen_at: now,
            registered: false,
            device_id: None,
        }
    }

    /// Time used once the trial has reached `seen`; never less than what `last_seen_at` records.
    pub fn elapsed_at(&self, seen: i64) -> i64 {
        (seen.max(self.last_seen_at) - self.started_at).max(0)
    }
}

/// What is known about the trial Keychain item.
#[derive(Clone, Debug, PartialEq)]
pub enum TrialSlot {
    /// Not read yet, or the read failed: never "no trial yet".
    Unread,
    /// The Keychain positively reported that the item does not exist.
    Absent,
    Present(TrialRecord),
}

/// The trial's length and offline limit. Only debug builds shorten them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrialTerms {
    pub length: i64,
    pub offline_limit: i64,
}

impl Default for TrialTerms {
    fn default() -> Self {
        Self {
            length: TRIAL_LENGTH,
            offline_limit: TRIAL_OFFLINE_LIMIT,
        }
    }
}

impl TrialTerms {
    /// A shorter trial for manual end-to-end runs; the offline limit keeps its share of it.
    pub fn shortened(length: i64) -> Self {
        let length = length.clamp(60, TRIAL_LENGTH);
        Self {
            length,
            offline_limit: (length / 3).min(TRIAL_OFFLINE_LIMIT),
        }
    }
}

/// The trial's position at the last tick: `last_seen_at` then, and the monotonic clock then.
/// Not saved: each run measures from its own launch.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrialAnchor {
    pub seen: i64,
    pub mono: i64,
}

/// Lowercase hex SHA-256 of `openapps-trial-v1:<app id>:<hardware id>`. The app id salts it, so
/// one Mac's hashes for two apps don't match, and the hardware id never leaves the Mac.
pub fn device_hash(app_id: &str, hardware_id: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(format!("{DEVICE_HASH_VERSION}:{app_id}:{hardware_id}"));
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The product IDs this app accepts for the current Dodo environment.
#[derive(Clone, Debug, PartialEq)]
pub struct Products {
    pub paid: Vec<String>,
}

impl Products {
    fn is_paid(&self, product_id: &str) -> bool {
        self.paid.iter().any(|id| id == product_id)
    }

    /// Whether a stored record is a license: not a retired trial key, and for this app's paid
    /// product in this environment.
    pub fn licenses(&self, record: &Record) -> bool {
        record.kind.as_deref() != Some(LEGACY_TRIAL_KIND) && self.is_paid(&record.product_id)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DodoError {
    /// Activate `404`.
    KeyNotFound,
    /// Activate `403`.
    KeyDisabled,
    /// Activate `422`.
    LimitReached,
    /// `429`; seconds from `Retry-After`.
    RateLimited { retry_after: i64 },
    /// Timeout or no network: grace rules apply and state never gets worse.
    Offline(String),
    /// `5xx`: Dodo is reachable but failing; treated like being offline.
    ServerError(u16),
    /// A response the app does not understand; treated like being offline.
    Unexpected(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Activation {
    pub id: String,
    pub product_id: String,
    pub product_name: String,
    pub created_at: i64,
    /// The response `Date` header, when present.
    pub server_time: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Validation {
    pub valid: bool,
    pub server_time: Option<i64>,
}

/// Dodo Payments' public license endpoints. Only the key and activation ID ever leave the Mac.
pub trait Dodo {
    fn activate(&self, license_key: &str, name: &str) -> Result<Activation, DodoError>;
    fn validate(&self, license_key: &str, instance_id: &str) -> Result<Validation, DodoError>;
    fn deactivate(&self, license_key: &str, instance_id: &str) -> Result<(), DodoError>;
}

/// The registry's answer: the stored start and its own clock, both server time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RegistryAnswer {
    pub started_at: i64,
    pub now: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum RegistryError {
    /// `429`; seconds from `Retry-After`.
    RateLimited { retry_after: i64 },
    /// Timeout or no network.
    Offline(String),
    /// Any other answer; counts as offline.
    Unexpected(String),
}

/// The trial registry. Only the device hash, app id and environment leave the Mac.
pub trait Registry {
    fn register(&self, device: &str) -> Result<RegistryAnswer, RegistryError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "state",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum State {
    /// No license and no trial running: the trial record is unreadable or not saved yet.
    Unlicensed,
    /// `days_left` rounds up; `0` means less than a day is left.
    Trial {
        days_left: u32,
    },
    TrialEnded,
    /// An unregistered trial reached the offline limit; the registry's answer decides.
    TrialOffline,
    /// At launch or wake the clock was more than an hour behind the trial's latest moment: off
    /// until the clock is corrected. No time is added meanwhile.
    ClockBehind,
    Licensed,
    Grace {
        days_offline: u32,
        days_left: u32,
    },
    CheckRequired,
    Revoked,
}

impl State {
    /// Whether keyboard sounds play. Everything else in the app always works.
    pub fn core_feature(&self) -> bool {
        matches!(
            self,
            State::Trial { .. } | State::Licensed | State::Grace { .. }
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum LicenseError {
    EmptyKey,
    KeyNotFound,
    KeyDisabled,
    LimitReached,
    Unreachable,
    RateLimited {
        retry_after: i64,
    },
    WrongProduct {
        product_name: String,
    },
    NothingToRemove,
    RemoveOffline,
    /// The Keychain refused the record; the activation was given back.
    NotSaved(String),
}

impl LicenseError {
    pub fn message(&self) -> String {
        match self {
            LicenseError::EmptyKey => "Paste your license key first.".into(),
            LicenseError::KeyNotFound => "This license key was not found. Check it and try again.".into(),
            LicenseError::KeyDisabled => "This license key is disabled or expired.".into(),
            LicenseError::LimitReached => {
                "All 3 Macs for this license are already activated. Remove one from another Mac, or contact support."
                    .into()
            }
            LicenseError::Unreachable => {
                format!("{APP_NAME} couldn't reach the license service. Check your connection and try again.")
            }
            LicenseError::RateLimited { retry_after } => format!(
                "The license service is busy. Try again in {}.",
                if *retry_after > 90 {
                    format!("{} minutes", (retry_after + 59) / 60)
                } else {
                    "a minute".to_string()
                }
            ),
            LicenseError::WrongProduct { product_name } => {
                format!("This key is for {product_name}, not {APP_NAME}.")
            }
            LicenseError::NothingToRemove => "This Mac has no license to remove.".into(),
            LicenseError::RemoveOffline => format!(
                "{APP_NAME} couldn't reach the license service, so this Mac is still activated. Connect to the internet and try again."
            ),
            LicenseError::NotSaved(reason) => {
                format!("{reason} This Mac was not activated; try again.")
            }
        }
    }
}

impl From<DodoError> for LicenseError {
    fn from(error: DodoError) -> Self {
        match error {
            DodoError::KeyNotFound => LicenseError::KeyNotFound,
            DodoError::KeyDisabled => LicenseError::KeyDisabled,
            DodoError::LimitReached => LicenseError::LimitReached,
            DodoError::RateLimited { retry_after } => LicenseError::RateLimited { retry_after },
            DodoError::Offline(_) | DodoError::ServerError(_) | DodoError::Unexpected(_) => {
                LicenseError::Unreachable
            }
        }
    }
}

/// When the next check may run. Rate limits are hard holds; backoff after failures is soft and a
/// user's "Try again" skips it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Schedule {
    pub failures: u32,
    /// The next attempt, on the local clock: a day after any answer, sooner with backoff.
    pub next_attempt_at: Option<i64>,
    pub hold_until: Option<i64>,
    /// The last failure was at the network level, so a reachability probe is worth running.
    pub network_down: bool,
}

impl Schedule {
    fn backoff(failures: u32) -> i64 {
        let doubled = MIN_BACKOFF.saturating_mul(1i64 << failures.saturating_sub(1).min(20));
        if doubled >= MAX_BACKOFF {
            // The hour-long retry was the last of the backoff series; after it, the daily schedule applies.
            if failures > 7 {
                CHECK_INTERVAL
            } else {
                MAX_BACKOFF
            }
        } else {
            doubled
        }
    }

    /// Dodo did not answer: retry with backoff.
    fn failed(&mut self, now: i64, network_down: bool) {
        self.failures += 1;
        self.next_attempt_at = Some(now + Self::backoff(self.failures));
        self.network_down = network_down;
    }

    /// Dodo answered, whatever it said: back to the daily schedule from now.
    fn answered(&mut self, now: i64) {
        *self = Self {
            next_attempt_at: Some(now + CHECK_INTERVAL),
            ..Self::default()
        };
    }

    /// `429`: no call of any kind until `Retry-After` has passed. Not a failure, so the state
    /// does not change.
    fn hold(&mut self, now: i64, retry_after: i64) {
        self.hold_until = Some(now + retry_after.clamp(1, MAX_HOLD));
    }
}

/// When the trial registry may be asked again: backoff from a minute up to an hour, and its own
/// `Retry-After` holds, independent of Dodo's.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Registration {
    pub failures: u32,
    pub next_attempt_at: Option<i64>,
    pub hold_until: Option<i64>,
    pub network_down: bool,
}

impl Registration {
    fn failed(&mut self, now: i64, network_down: bool) {
        self.failures += 1;
        let backoff = MIN_BACKOFF
            .saturating_mul(1i64 << self.failures.saturating_sub(1).min(20))
            .min(MAX_BACKOFF);
        self.next_attempt_at = Some(now + backoff);
        self.network_down = network_down;
    }

    fn held(&self, now: i64) -> bool {
        self.hold_until.is_some_and(|until| now < until)
    }
}

/// One activation named precisely enough to deactivate or to match a validation answer to.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Probe {
    pub license_key: String,
    pub instance_id: String,
}

/// A successful activation that is not yet in effect: the caller persists `next` first and then
/// commits, or abandons it (giving the slot back) when the record cannot be saved.
#[derive(Clone, Debug, PartialEq)]
pub struct Activated {
    pub next: Stored,
    pub replaced: Option<Probe>,
    pub probe: Probe,
}

pub struct Engine {
    pub stored: Stored,
    pub trial: TrialSlot,
    pub products: Products,
    pub schedule: Schedule,
    pub registration: Registration,
    pub terms: TrialTerms,
    /// Where the running trial was at the last tick, so elapsed time follows the monotonic clock.
    pub trial_anchor: Option<TrialAnchor>,
    /// Set when launch or wake found the clock behind the trial; cleared once it is corrected.
    pub clock_behind: bool,
    /// A registry answer that arrived while the clock was behind, with the monotonic time it
    /// arrived at. Applied once the clock is corrected.
    pub pending_registration: Option<(RegistryAnswer, i64)>,
}

impl Engine {
    /// An engine whose trial record is positively absent.
    pub fn new(stored: Stored, products: Products) -> Self {
        Self {
            stored,
            trial: TrialSlot::Absent,
            products,
            schedule: Schedule::default(),
            registration: Registration::default(),
            terms: TrialTerms::default(),
            trial_anchor: None,
            clock_behind: false,
            pending_registration: None,
        }
    }

    /// The stored record, if it is a license. A retired trial key's record or another product's
    /// is kept (for cleanup and the journal) but never grants paid access.
    pub fn license(&self) -> Option<&Record> {
        Self::license_in(&self.stored, &self.products)
    }

    fn license_in<'a>(stored: &'a Stored, products: &Products) -> Option<&'a Record> {
        stored
            .license
            .as_ref()
            .filter(|record| products.licenses(record))
    }

    fn local_anchor(record: &Record) -> i64 {
        if record.last_success_local > 0 {
            record.last_success_local
        } else {
            record.last_success_at
        }
    }

    /// The current moment on the server's clock: its time at the last answer plus the local
    /// time elapsed since. Rolling the local clock back moves this back too.
    fn anchored_now(record: &Record, now: i64) -> i64 {
        record.last_success_at + (now - Self::local_anchor(record))
    }

    /// Whether the clock can be trusted: not materially earlier than the latest moment seen.
    fn clock_trusted(record: &Record, now: i64) -> bool {
        Self::anchored_now(record, now) >= record.last_observed_at - CLOCK_ROLLBACK_TOLERANCE
    }

    /// Whether a paid license needs a check because the clock was set back.
    pub fn clock_changed(&self, at: impl Into<Moment>) -> bool {
        let now = at.into().wall;
        self.license()
            .is_some_and(|record| !record.revoked && !Self::clock_trusted(record, now))
    }

    /// The moment the trial has reached: `last_seen_at` plus the monotonic time since the last
    /// tick, and never before the wall clock. While the clock is behind, no time is added.
    fn trial_seen(&self, trial: &TrialRecord, at: Moment) -> i64 {
        let mut seen = trial.last_seen_at.max(at.wall);
        if !self.clock_behind
            && let Some(anchor) = self.trial_anchor
        {
            seen = seen.max(anchor.seen + (at.mono - anchor.mono).max(0));
        }
        seen
    }

    /// Whether the trial is held because launch or wake found the clock behind it. The hold is
    /// latched: it restricts access and freezes trial writes until a fresh `observe` finds the
    /// clock corrected, even if the wall clock already looks right. `at` is unused but keeps the
    /// call sites uniform.
    pub fn trial_clock_behind(&self, _at: impl Into<Moment>) -> bool {
        self.clock_behind
            && self.license().is_none()
            && matches!(&self.trial, TrialSlot::Present(_))
    }

    /// Whether a held trial's clock looks corrected at `at`. This only tells the scheduler to
    /// observe soon; it never grants anything by itself.
    pub fn clock_corrected(&self, at: impl Into<Moment>) -> bool {
        let at = at.into();
        self.trial_clock_behind(at) && !self.wall_behind_trial(at)
    }

    /// Whether the wall clock is more than the tolerance behind the trial's latest moment.
    fn wall_behind_trial(&self, at: Moment) -> bool {
        matches!(&self.trial, TrialSlot::Present(trial)
            if at.wall < trial.last_seen_at - CLOCK_ROLLBACK_TOLERANCE)
    }

    /// Launch or wake: with no license, a clock more than an hour behind the trial holds it until
    /// the clock is corrected.
    pub fn check_clock(&mut self, at: impl Into<Moment>) {
        let at = at.into();
        if !self.stale(at)
            && self.license().is_none()
            && let TrialSlot::Present(trial) = &self.trial
            && at.wall < self.trial_seen(trial, at) - CLOCK_ROLLBACK_TOLERANCE
        {
            self.clock_behind = true;
        }
    }

    /// Whether `at` is older, on the monotonic clock, than the trial's anchor.
    fn stale(&self, at: Moment) -> bool {
        self.trial_anchor
            .is_some_and(|anchor| at.mono < anchor.mono)
    }

    /// Starts measuring the trial's elapsed time on the monotonic clock from `at`. The anchor
    /// never moves back.
    pub fn anchor_trial(&mut self, at: impl Into<Moment>) {
        let at = at.into();
        if !self.stale(at)
            && let TrialSlot::Present(trial) = &self.trial
        {
            self.trial_anchor = Some(TrialAnchor {
                seen: trial.last_seen_at,
                mono: at.mono,
            });
        }
    }

    pub fn state(&self, at: impl Into<Moment>) -> State {
        let at = at.into();
        if let Some(record) = self.license() {
            return Self::paid_state(record, &self.schedule, at.wall);
        }
        match &self.trial {
            TrialSlot::Present(trial) => self.trial_state_now(trial, at),
            TrialSlot::Unread | TrialSlot::Absent => State::Unlicensed,
        }
    }

    fn trial_state_now(&self, trial: &TrialRecord, at: Moment) -> State {
        let ended = Self::trial_state(trial, &self.terms, trial.last_seen_at) == State::TrialEnded;
        if !ended && self.trial_clock_behind(at) {
            State::ClockBehind
        } else {
            Self::trial_state(trial, &self.terms, self.trial_seen(trial, at))
        }
    }

    /// The state the saved records allow at `at`, measured with this engine's clock so an
    /// unsaved extension never unlocks by itself.
    pub fn durable_state(
        &self,
        stored: &Stored,
        trial: &TrialSlot,
        at: impl Into<Moment>,
    ) -> State {
        let at = at.into();
        if let Some(record) = Self::license_in(stored, &self.products) {
            return Self::paid_state(record, &Schedule::default(), at.wall);
        }
        let TrialSlot::Present(saved) = trial else {
            return State::Unlicensed;
        };
        let seen = match &self.trial {
            TrialSlot::Present(current) => self.trial_seen(current, at),
            _ => at.wall,
        };
        if self.trial_clock_behind(at) {
            return State::ClockBehind;
        }
        Self::trial_state(saved, &self.terms, seen)
    }

    /// The trial's state once it has reached `seen`.
    pub fn trial_state(trial: &TrialRecord, terms: &TrialTerms, seen: i64) -> State {
        let elapsed = trial.elapsed_at(seen);
        if elapsed >= terms.length {
            State::TrialEnded
        } else if !trial.registered && elapsed >= terms.offline_limit {
            State::TrialOffline
        } else {
            let remaining = terms.length - elapsed;
            State::Trial {
                days_left: if remaining < DAY {
                    0
                } else {
                    days_up(remaining)
                },
            }
        }
    }

    fn paid_state(record: &Record, schedule: &Schedule, now: i64) -> State {
        if record.revoked {
            return State::Revoked;
        }
        let age = Self::anchored_now(record, now) - record.last_success_at;
        if !Self::clock_trusted(record, now) || age > GRACE_PERIOD {
            State::CheckRequired
        } else if age > CHECK_INTERVAL && schedule.failures > 0 {
            State::Grace {
                days_offline: (age / DAY) as u32,
                days_left: days_up(GRACE_PERIOD - age),
            }
        } else {
            State::Licensed
        }
    }

    /// How long a paid license has gone without a successful check, by the trusted clock.
    pub fn offline_for(&self, at: impl Into<Moment>) -> Option<i64> {
        let now = at.into().wall;
        self.license()
            .map(|record| Self::anchored_now(record, now) - record.last_success_at)
    }

    /// Notes that `at` has been reached: raises the license's latest moment and the trial's
    /// `last_seen_at` (by the monotonic time since the last tick, and to the wall clock). A
    /// corrected clock ends the hold from launch or wake without adding the time it lasted.
    /// Returns which records changed.
    pub fn observe(&mut self, at: impl Into<Moment>) -> Observed {
        let at = at.into();
        if self.stale(at) {
            // Sampled before a newer observation landed: it changes nothing, so the anchor,
            // `last_seen_at` and the clock hold only ever move forward.
            return Observed::default();
        }
        let license = self.license().is_some()
            && match self.stored.license.as_mut() {
                Some(record) if Self::anchored_now(record, at.wall) > record.last_observed_at => {
                    record.last_observed_at = Self::anchored_now(record, at.wall);
                    true
                }
                _ => false,
            };
        if self.trial_clock_behind(at) && self.wall_behind_trial(at) {
            // Still behind: the hold stays, and nothing about the trial changes.
            return Observed {
                license,
                trial: false,
            };
        }
        // A fresh observation is the only way out of the hold: it re-anchors below, and the
        // time the hold lasted is not counted (`trial_seen` adds no monotonic time while held).
        let seen = match &self.trial {
            TrialSlot::Present(trial) => self.trial_seen(trial, at),
            _ => {
                return Observed {
                    license,
                    trial: false,
                };
            }
        };
        self.clock_behind = false;
        let TrialSlot::Present(trial) = &mut self.trial else {
            unreachable!("checked above");
        };
        let raised = seen > trial.last_seen_at;
        trial.last_seen_at = trial.last_seen_at.max(seen);
        self.trial_anchor = Some(TrialAnchor {
            seen: trial.last_seen_at,
            mono: at.mono,
        });
        // The clock is trustworthy again: a registry answer held meanwhile is applied now.
        let registered = match self.pending_registration.take() {
            Some((answer, received_mono)) => {
                self.apply_registration(answer, at.wall, (at.mono - received_mono).max(0))
            }
            None => false,
        };
        Observed {
            license,
            trial: raised || registered,
        }
    }

    /// Converts the registry's start to local time and keeps the earlier start. `since_answer`
    /// is the monotonic time since the answer arrived, which the registry's clock has moved on
    /// by too.
    fn apply_registration(&mut self, answer: RegistryAnswer, wall: i64, since_answer: i64) -> bool {
        let TrialSlot::Present(trial) = &mut self.trial else {
            return false;
        };
        if trial.registered {
            return false;
        }
        let registry_now = answer.now.saturating_add(since_answer);
        let registry_start = wall.saturating_sub(registry_now.saturating_sub(answer.started_at));
        trial.started_at = trial.started_at.min(registry_start);
        trial.registered = true;
        true
    }

    /// Whether trial writes are frozen: the clock is behind, so nothing about the trial may be
    /// saved or changed until it is corrected.
    pub fn trial_frozen(&self, at: impl Into<Moment>) -> bool {
        self.trial_clock_behind(at)
    }

    pub fn is_held(&self, at: impl Into<Moment>) -> bool {
        self.held(at.into().wall).is_err()
    }

    fn held(&self, now: i64) -> Result<(), LicenseError> {
        match self.schedule.hold_until {
            Some(hold_until) if now < hold_until => Err(LicenseError::RateLimited {
                retry_after: hold_until - now,
            }),
            _ => Ok(()),
        }
    }

    /// When the scheduler should run the next check, or `None` while there is nothing to check.
    pub fn next_check_at(&self, at: impl Into<Moment>) -> Option<i64> {
        let now = at.into().wall;
        let record = self.license()?;
        // The schedule lives on the local clock; before any attempt this run, a day after the
        // last answer's local moment.
        let mut due = if !Self::clock_trusted(record, now) && self.schedule.failures == 0 {
            // An untrusted clock needs Dodo's answer now, whatever was scheduled; once an
            // attempt has failed, the backoff decides.
            now
        } else {
            self.schedule
                .next_attempt_at
                .unwrap_or_else(|| Self::local_anchor(record) + CHECK_INTERVAL)
        };
        if let Some(hold_until) = self.schedule.hold_until {
            due = due.max(hold_until);
        }
        Some(due)
    }

    pub fn check_due(&self, at: impl Into<Moment>) -> bool {
        let now = at.into().wall;
        self.next_check_at(now).is_some_and(|due| due <= now)
    }

    /// The next wall-clock moment the state changes by time alone: the trial's end or offline
    /// limit, the grace warning, or the end of grace. Independent of any network schedule.
    pub fn next_transition_at(&self, at: impl Into<Moment>) -> Option<i64> {
        let at = at.into();
        match (self.license(), &self.trial) {
            (Some(record), _) if record.revoked => None,
            (Some(record), _) => {
                let anchor = Self::local_anchor(record);
                [anchor + GRACE_WARNING_AFTER, anchor + GRACE_PERIOD]
                    .into_iter()
                    .filter(|moment| *moment > at.wall)
                    .min()
            }
            (None, TrialSlot::Present(trial)) => self.trial_transition_at(trial, at),
            (None, _) => None,
        }
    }

    /// The next wall-clock moment a trial record's state changes, measured with this engine's
    /// clock: its end, or its offline limit while unregistered. Also used for the saved record.
    pub fn trial_transition_at(&self, trial: &TrialRecord, at: impl Into<Moment>) -> Option<i64> {
        let at = at.into();
        if self.trial_clock_behind(at) {
            return None;
        }
        let seen = match &self.trial {
            TrialSlot::Present(current) => self.trial_seen(current, at),
            _ => at.wall,
        };
        let elapsed = trial.elapsed_at(seen);
        let mut limits = vec![self.terms.length];
        if !trial.registered {
            limits.push(self.terms.offline_limit);
        }
        limits
            .into_iter()
            .filter(|limit| *limit > elapsed)
            .map(|limit| at.wall + (limit - elapsed))
            .min()
    }

    /// A provisional trial to save, when there is no license and the trial record is positively
    /// absent. A retired trial key's record keeps its own start, so it gains no time. Nothing
    /// changes until the caller has saved it and calls `commit_trial`.
    pub fn provisional_trial(&self, at: impl Into<Moment>) -> Option<TrialRecord> {
        let now = at.into().wall;
        if self.license().is_some() || self.trial != TrialSlot::Absent {
            return None;
        }
        let started_at = self
            .stored
            .license
            .as_ref()
            .map_or(now, |legacy| legacy.activated_at);
        Some(TrialRecord::provisional(started_at, now))
    }

    /// Puts a saved trial record into effect, measuring from `at`.
    pub fn commit_trial(&mut self, trial: TrialRecord, at: impl Into<Moment>) {
        self.trial = TrialSlot::Present(trial);
        self.anchor_trial(at);
    }

    /// Whether the registry should still be asked: an unregistered trial with time left, and no
    /// license in the way. A registered trial never contacts the registry again.
    pub fn registration_wanted(&self, at: impl Into<Moment>) -> bool {
        let at = at.into();
        self.license().is_none()
            && self.pending_registration.is_none()
            && matches!(&self.trial, TrialSlot::Present(trial)
                if !trial.registered
                    && trial.elapsed_at(self.trial_seen(trial, at)) < self.terms.length)
    }

    /// When the registry may be asked next, or `None` while there is nothing to ask.
    pub fn next_registration_at(&self, at: impl Into<Moment>) -> Option<i64> {
        let at = at.into();
        if !self.registration_wanted(at) {
            return None;
        }
        let due = self.registration.next_attempt_at.unwrap_or(at.wall);
        Some(match self.registration.hold_until {
            Some(hold_until) => due.max(hold_until),
            None => due,
        })
    }

    /// Whether to ask the registry now. `forced` (launch, wake, network back, Try again) skips
    /// the backoff but never a rate limit.
    pub fn begin_registration(&self, at: impl Into<Moment>, forced: bool) -> bool {
        let at = at.into();
        self.registration_wanted(at)
            && !self.registration.held(at.wall)
            && (forced
                || self
                    .registration
                    .next_attempt_at
                    .is_none_or(|due| due <= at.wall))
    }

    /// Applies the registry's answer. On success the registry's start is converted to local time
    /// and the earlier of it and the provisional start is kept; while the clock is behind, the
    /// raw answer is held and applied by `observe` once the clock is corrected. Returns whether
    /// the trial record changed and needs saving.
    pub fn finish_registration(
        &mut self,
        answer: Result<RegistryAnswer, RegistryError>,
        at: impl Into<Moment>,
    ) -> Result<bool, RegistryError> {
        let at = at.into();
        let now = at.wall;
        match answer {
            Ok(answer) => {
                self.registration = Registration::default();
                if self.trial_frozen(at) {
                    self.pending_registration = Some((answer, at.mono));
                    return Ok(false);
                }
                Ok(self.apply_registration(answer, now, 0))
            }
            Err(RegistryError::RateLimited { retry_after }) => {
                self.registration.hold_until = Some(now + retry_after.clamp(1, MAX_HOLD));
                Err(RegistryError::RateLimited { retry_after })
            }
            Err(error) => {
                self.registration
                    .failed(now, matches!(error, RegistryError::Offline(_)));
                Err(error)
            }
        }
    }

    /// Whether an activation call may be made now.
    pub fn activation_allowed(&self, key: &str, at: impl Into<Moment>) -> Result<(), LicenseError> {
        if key.trim().is_empty() {
            return Err(LicenseError::EmptyKey);
        }
        self.held(at.into().wall)
    }

    /// `429`: nothing is called again until `Retry-After` has passed.
    pub fn note_rate_limit(&mut self, at: impl Into<Moment>, retry_after: i64) {
        self.schedule.hold(at.into().wall, retry_after);
    }

    /// Applies the product check to a fresh activation. Nothing is stored yet: the caller
    /// persists `Activated::next` before `commit_activation`, and gives a refused or unsaved
    /// activation's slot back with `apply_release`.
    pub fn accept_activation(
        &self,
        key: &str,
        activation: Activation,
        at: impl Into<Moment>,
    ) -> Result<Activated, Refusal> {
        let now = at.into().wall;
        let probe = Probe {
            license_key: key.trim().to_string(),
            instance_id: activation.id,
        };
        if !self.products.is_paid(&activation.product_id) {
            // Another app's key, the wrong environment, or a retired trial product.
            return Err(Refusal {
                probe,
                error: LicenseError::WrongProduct {
                    product_name: activation.product_name,
                },
            });
        }
        // Whatever the stored record was, a license or a retired trial key, its slot goes back.
        let replaced = self
            .stored
            .license
            .as_ref()
            .filter(|previous| previous.instance_id != probe.instance_id)
            .map(|previous| Probe {
                license_key: previous.license_key.clone(),
                instance_id: previous.instance_id.clone(),
            });
        let mut next = self.stored.clone();
        next.license = Some(Record {
            license_key: probe.license_key.clone(),
            instance_id: probe.instance_id.clone(),
            product_id: activation.product_id,
            kind: None,
            activated_at: activation.created_at,
            last_success_at: activation.server_time.unwrap_or(now),
            last_success_local: now,
            last_observed_at: activation.server_time.unwrap_or(now),
            revoked: false,
            event_seq: 1,
        });
        Ok(Activated {
            next,
            replaced,
            probe,
        })
    }

    /// Puts a saved activation into effect. Returns the activation it replaced, whose slot the
    /// caller frees with `apply_release`.
    pub fn commit_activation(
        &mut self,
        activated: Activated,
        at: impl Into<Moment>,
    ) -> Option<Probe> {
        self.stored = activated.next;
        self.schedule.answered(at.into().wall);
        activated.replaced
    }

    /// Records the outcome of deactivating an activation this Mac no longer uses. A failure is
    /// remembered in `Stored::pending_cleanups` and retried through `take_cleanups`, so a slot is
    /// never lost.
    pub fn apply_release(
        &mut self,
        probe: Probe,
        answer: Result<(), DodoError>,
        at: impl Into<Moment>,
    ) {
        match answer {
            Ok(()) | Err(DodoError::KeyNotFound) | Err(DodoError::KeyDisabled) => {}
            Err(error) => {
                if let DodoError::RateLimited { retry_after } = error {
                    self.schedule.hold(at.into().wall, retry_after);
                }
                self.remember_cleanup(probe);
            }
        }
    }

    pub fn remember_cleanup(&mut self, probe: Probe) {
        if !self.stored.pending_cleanups.contains(&probe) {
            self.stored.pending_cleanups.push(probe);
        }
    }

    /// Deactivations to retry now; empty while a rate limit holds. Each answer goes back through
    /// `apply_release`.
    pub fn take_cleanups(&mut self, at: impl Into<Moment>) -> Vec<Probe> {
        if self.held(at.into().wall).is_err() {
            return Vec::new();
        }
        std::mem::take(&mut self.stored.pending_cleanups)
    }

    /// Starts a validation of the license. `Ok(None)` when there is no license, or the check is
    /// not due and not forced. The answer goes to `finish_check`, which ignores it if the record
    /// changed.
    pub fn begin_check(
        &self,
        at: impl Into<Moment>,
        forced: bool,
    ) -> Result<Option<Probe>, LicenseError> {
        let now = at.into().wall;
        let Some(record) = self.license() else {
            return Ok(None);
        };
        if !forced && !self.check_due(now) {
            return Ok(None);
        }
        self.held(now)?;
        Ok(Some(Probe {
            license_key: record.license_key.clone(),
            instance_id: record.instance_id.clone(),
        }))
    }

    /// Applies Dodo's answer to the activation it was asked about. An answer for an activation
    /// that has since been replaced or removed changes nothing.
    pub fn finish_check(
        &mut self,
        probe: &Probe,
        answer: Result<Validation, DodoError>,
        at: impl Into<Moment>,
    ) -> Result<State, LicenseError> {
        let at = at.into();
        let now = at.wall;
        let current = self
            .stored
            .license
            .as_mut()
            .filter(|record| record.instance_id == probe.instance_id);
        let Some(record) = current else {
            return Ok(self.state(at));
        };
        match answer {
            Ok(validation) => {
                if validation.valid {
                    // Dodo's answer anchors time again, and clears a revocation of this
                    // activation.
                    record.last_success_at = validation.server_time.unwrap_or(now);
                    record.last_success_local = now;
                    // The server's time is authoritative: local observations only ever raise
                    // this, but an answer from Dodo sets it.
                    record.last_observed_at = record.last_success_at;
                    record.revoked = false;
                } else {
                    record.revoked = true;
                }
                record.event_seq += 1;
                self.schedule.answered(now);
                Ok(self.state(at))
            }
            Err(DodoError::RateLimited { retry_after }) => {
                self.schedule.hold(now, retry_after);
                Err(LicenseError::RateLimited { retry_after })
            }
            Err(error) => {
                self.schedule
                    .failed(now, matches!(error, DodoError::Offline(_)));
                Err(LicenseError::Unreachable)
            }
        }
    }

    /// Settings → License → Remove this Mac: the activation to deactivate, or why not now.
    pub fn begin_remove(&self, at: impl Into<Moment>) -> Result<Probe, LicenseError> {
        let Some(record) = &self.stored.license else {
            return Err(LicenseError::NothingToRemove);
        };
        if self.held(at.into().wall).is_err() {
            return Err(LicenseError::RemoveOffline);
        }
        Ok(Probe {
            license_key: record.license_key.clone(),
            instance_id: record.instance_id.clone(),
        })
    }

    /// Clears the record once Dodo has deactivated it (or no longer knows it). If the record
    /// changed meanwhile the answer is ignored. The trial record is never touched.
    pub fn finish_remove(
        &mut self,
        probe: &Probe,
        answer: Result<(), DodoError>,
        at: impl Into<Moment>,
    ) -> Result<State, LicenseError> {
        let at = at.into();
        let matches = self
            .stored
            .license
            .as_ref()
            .is_some_and(|record| record.instance_id == probe.instance_id);
        match answer {
            // Already gone on Dodo's side: the slot is free, so forget it here too.
            Ok(()) | Err(DodoError::KeyNotFound) | Err(DodoError::KeyDisabled) => {
                if matches {
                    self.stored.license = None;
                    self.schedule = Schedule::default();
                }
                Ok(self.state(at))
            }
            Err(DodoError::RateLimited { retry_after }) => {
                self.schedule.hold(at.wall, retry_after);
                Err(LicenseError::RemoveOffline)
            }
            Err(_) => Err(LicenseError::RemoveOffline),
        }
    }
}

/// Which records `Engine::observe` changed.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Observed {
    pub license: bool,
    pub trial: bool,
}

/// An activation Dodo accepted but this app refuses: the slot goes back.
#[derive(Clone, Debug, PartialEq)]
pub struct Refusal {
    pub probe: Probe,
    pub error: LicenseError,
}

/// The full sequences the runtime performs, with a Dodo client in place of its network calls.
/// Tests drive these; the runtime interleaves the same steps with its locks and the Keychain.
#[cfg(test)]
impl Engine {
    pub fn core_feature(&self, at: impl Into<Moment>) -> bool {
        self.state(at).core_feature()
    }

    pub fn activate(
        &mut self,
        key: &str,
        dodo: &dyn Dodo,
        now: i64,
    ) -> Result<Activated, LicenseError> {
        self.activation_allowed(key, now)?;
        let activation = match dodo.activate(key.trim(), ACTIVATION_NAME) {
            Ok(activation) => activation,
            Err(DodoError::RateLimited { retry_after }) => {
                self.note_rate_limit(now, retry_after);
                return Err(LicenseError::RateLimited { retry_after });
            }
            Err(error) => return Err(error.into()),
        };
        match self.accept_activation(key, activation, now) {
            Ok(activated) => Ok(activated),
            Err(Refusal { probe, error }) => {
                self.release(probe, dodo, now);
                Err(error)
            }
        }
    }

    pub fn commit(&mut self, activated: Activated, dodo: &dyn Dodo, now: i64) -> State {
        if let Some(replaced) = self.commit_activation(activated, now) {
            self.release(replaced, dodo, now);
        }
        self.state(now)
    }

    pub fn abandon_activation(&mut self, activated: Activated, dodo: &dyn Dodo, now: i64) {
        self.release(activated.probe, dodo, now);
    }

    fn release(&mut self, probe: Probe, dodo: &dyn Dodo, now: i64) {
        if self.held(now).is_err() {
            self.remember_cleanup(probe);
            return;
        }
        let answer = dodo.deactivate(&probe.license_key, &probe.instance_id);
        self.apply_release(probe, answer, now);
    }

    pub fn release_cleanups(&mut self, dodo: &dyn Dodo, now: i64) -> bool {
        let pending = self.take_cleanups(now);
        let before = pending.len();
        for probe in pending {
            self.release(probe, dodo, now);
        }
        before > 0 && self.stored.pending_cleanups.len() != before
    }

    pub fn check(&mut self, dodo: &dyn Dodo, now: i64) -> Result<State, LicenseError> {
        let Some(probe) = self.begin_check(now, true)? else {
            return Ok(self.state(now));
        };
        let answer = dodo.validate(&probe.license_key, &probe.instance_id);
        self.finish_check(&probe, answer, now)
    }

    pub fn remove(&mut self, dodo: &dyn Dodo, now: i64) -> Result<State, LicenseError> {
        let probe = self.begin_remove(now)?;
        let answer = dodo.deactivate(&probe.license_key, &probe.instance_id);
        self.finish_remove(&probe, answer, now)
    }

    /// One scheduler pass of registration: `Ok(None)` when nothing was asked.
    pub fn register(
        &mut self,
        registry: &dyn Registry,
        now: i64,
    ) -> Result<Option<State>, RegistryError> {
        if !self.begin_registration(now, false) {
            return Ok(None);
        }
        let answer = registry.register(&device_hash(APP_ID, "TEST-UUID"));
        self.finish_registration(answer, now)?;
        Ok(Some(self.state(now)))
    }
}

fn days_up(seconds: i64) -> u32 {
    ((seconds.max(0) + DAY - 1) / DAY) as u32
}

#[cfg(test)]
pub(crate) mod tests {
    //! The shared test cases from LICENSING.md that need no Keychain or threads, numbered as in
    //! the document. The rest are in `runtime.rs`.
    use super::*;
    use std::cell::RefCell;

    const P: &str = "pdt_openklack";
    const X: &str = "pdt_openreaction";
    const NOW: i64 = 1_800_000_000;
    const HOUR: i64 = 3600;

    #[derive(Debug, PartialEq, Clone)]
    enum Call {
        Activate(String, String),
        Validate(String, String),
        Deactivate(String, String),
    }

    #[derive(Default)]
    struct Fake {
        activate: RefCell<Vec<Result<Activation, DodoError>>>,
        validate: RefCell<Vec<Result<Validation, DodoError>>>,
        deactivate: RefCell<Vec<Result<(), DodoError>>>,
        /// Answered once the scripted queues are empty: a service that stays down.
        sticky: Option<DodoError>,
        calls: RefCell<Vec<Call>>,
    }

    impl Fake {
        fn activating(product_id: &str) -> Self {
            let fake = Self::default();
            fake.activate.borrow_mut().push(Ok(activation(product_id)));
            fake
        }
        fn validating(valid: bool) -> Self {
            let fake = Self::default();
            fake.validate.borrow_mut().push(Ok(Validation {
                valid,
                server_time: Some(NOW),
            }));
            fake
        }
        fn failing(error: DodoError) -> Self {
            Self {
                sticky: Some(error),
                ..Self::default()
            }
        }
        fn calls(&self) -> Vec<Call> {
            self.calls.borrow().clone()
        }
    }

    fn activation(product_id: &str) -> Activation {
        Activation {
            id: format!("lki_{product_id}"),
            product_id: product_id.into(),
            product_name: match product_id {
                P => "OpenKlack",
                _ => "OpenReaction",
            }
            .into(),
            created_at: NOW,
            server_time: Some(NOW),
        }
    }

    impl Dodo for Fake {
        fn activate(&self, key: &str, name: &str) -> Result<Activation, DodoError> {
            self.calls
                .borrow_mut()
                .push(Call::Activate(key.into(), name.into()));
            let mut queue = self.activate.borrow_mut();
            match (&self.sticky, queue.is_empty()) {
                (Some(error), true) => Err(error.clone()),
                (None, true) => Ok(activation(P)),
                _ => queue.remove(0),
            }
        }
        fn validate(&self, key: &str, instance: &str) -> Result<Validation, DodoError> {
            self.calls
                .borrow_mut()
                .push(Call::Validate(key.into(), instance.into()));
            let mut queue = self.validate.borrow_mut();
            match (&self.sticky, queue.is_empty()) {
                (Some(error), true) => Err(error.clone()),
                (None, true) => Ok(Validation {
                    valid: true,
                    server_time: None,
                }),
                _ => queue.remove(0),
            }
        }
        fn deactivate(&self, key: &str, instance: &str) -> Result<(), DodoError> {
            self.calls
                .borrow_mut()
                .push(Call::Deactivate(key.into(), instance.into()));
            let mut queue = self.deactivate.borrow_mut();
            match (&self.sticky, queue.is_empty()) {
                (Some(error), true) => Err(error.clone()),
                (None, true) => Ok(()),
                _ => queue.remove(0),
            }
        }
    }

    /// A scripted trial registry: queued answers, then `sticky`.
    struct FakeRegistry {
        answers: RefCell<Vec<Result<RegistryAnswer, RegistryError>>>,
        sticky: Result<RegistryAnswer, RegistryError>,
        calls: RefCell<Vec<String>>,
    }

    impl FakeRegistry {
        fn answering(answer: Result<RegistryAnswer, RegistryError>) -> Self {
            Self {
                answers: RefCell::new(Vec::new()),
                sticky: answer,
                calls: RefCell::new(Vec::new()),
            }
        }
        fn calls(&self) -> usize {
            self.calls.borrow().len()
        }
    }

    impl Registry for FakeRegistry {
        fn register(&self, device: &str) -> Result<RegistryAnswer, RegistryError> {
            self.calls.borrow_mut().push(device.into());
            let mut queue = self.answers.borrow_mut();
            if queue.is_empty() {
                self.sticky.clone()
            } else {
                queue.remove(0)
            }
        }
    }

    /// The runtime's happy path: activate, save, commit.
    fn activate(
        engine: &mut Engine,
        key: &str,
        dodo: &dyn Dodo,
        now: i64,
    ) -> Result<State, LicenseError> {
        let activated = engine.activate(key, dodo, now)?;
        Ok(engine.commit(activated, dodo, now))
    }

    fn products() -> Products {
        Products {
            paid: vec![P.into()],
        }
    }

    fn unlicensed() -> Engine {
        Engine::new(Stored::default(), products())
    }

    fn trial_record(elapsed: i64, registered: bool) -> TrialRecord {
        TrialRecord {
            started_at: NOW - elapsed,
            last_seen_at: NOW,
            registered,
            device_id: None,
        }
    }

    fn with_trial(mut engine: Engine, elapsed: i64, registered: bool) -> Engine {
        engine.trial = TrialSlot::Present(trial_record(elapsed, registered));
        engine
    }

    /// A registered trial `elapsed` seconds in.
    fn in_trial(elapsed: i64) -> Engine {
        with_trial(unlicensed(), elapsed, true)
    }

    fn trial_ended() -> Engine {
        in_trial(TRIAL_LENGTH + HOUR)
    }

    fn licensed(last_success_ago: i64) -> Engine {
        Engine::new(
            Stored {
                license: Some(Record {
                    license_key: "KEY-PAID".into(),
                    instance_id: "lki_paid".into(),
                    product_id: P.into(),
                    kind: None,
                    activated_at: NOW - 30 * DAY,
                    last_success_at: NOW - last_success_ago,
                    last_success_local: NOW - last_success_ago,
                    last_observed_at: NOW - last_success_ago,
                    revoked: false,
                    event_seq: 1,
                }),
                pending_cleanups: vec![],
            },
            products(),
        )
    }

    fn registry_start(started_ago: i64) -> Result<RegistryAnswer, RegistryError> {
        Ok(RegistryAnswer {
            started_at: NOW - started_ago,
            now: NOW,
        })
    }

    #[test]
    fn case_01_a_paid_key_during_or_after_the_trial_licenses_the_mac() {
        for mut engine in [in_trial(DAY), trial_ended()] {
            let trial = engine.trial.clone();
            let dodo = Fake::activating(P);
            assert_eq!(
                activate(&mut engine, " KEY-PAID ", &dodo, NOW),
                Ok(State::Licensed)
            );
            let record = engine.stored.license.as_ref().unwrap();
            assert_eq!(record.license_key, "KEY-PAID");
            assert_eq!(record.instance_id, "lki_pdt_openklack");
            assert_eq!(record.activated_at, NOW);
            assert_eq!(record.last_success_at, NOW);
            assert_eq!(engine.trial, trial, "the trial record is kept");
            assert!(engine.core_feature(NOW));
            assert_eq!(
                dodo.calls(),
                vec![Call::Activate("KEY-PAID".into(), "Mac".into())],
                "nothing needs deactivating"
            );
        }
    }

    #[test]
    fn case_02_another_apps_key_is_deactivated_and_nothing_is_saved() {
        for (mut engine, state) in [
            (in_trial(DAY), State::Trial { days_left: 2 }),
            (trial_ended(), State::TrialEnded),
        ] {
            let dodo = Fake::activating(X);
            let error = activate(&mut engine, "KEY-X", &dodo, NOW).unwrap_err();
            assert_eq!(
                error,
                LicenseError::WrongProduct {
                    product_name: "OpenReaction".into()
                }
            );
            assert_eq!(
                error.message(),
                "This key is for OpenReaction, not OpenKlack."
            );
            assert_eq!(engine.stored, Stored::default());
            assert_eq!(
                dodo.calls(),
                vec![
                    Call::Activate("KEY-X".into(), "Mac".into()),
                    Call::Deactivate("KEY-X".into(), "lki_pdt_openreaction".into())
                ]
            );
            assert_eq!(engine.state(NOW), state);
        }
    }

    #[test]
    fn case_03_all_macs_activated_leaves_the_trial_ended() {
        let mut engine = trial_ended();
        let dodo = Fake::failing(DodoError::LimitReached);
        let error = activate(&mut engine, "KEY-PAID", &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::LimitReached);
        assert!(error.message().starts_with("All 3 Macs"));
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert_eq!(engine.stored, Stored::default());
    }

    #[test]
    fn case_04_unknown_and_disabled_keys_are_refused_with_their_reason() {
        for (error, expected, message) in [
            (
                DodoError::KeyNotFound,
                LicenseError::KeyNotFound,
                "This license key was not found. Check it and try again.",
            ),
            (
                DodoError::KeyDisabled,
                LicenseError::KeyDisabled,
                "This license key is disabled or expired.",
            ),
        ] {
            let mut engine = trial_ended();
            let dodo = Fake::failing(error);
            let result = activate(&mut engine, "KEY", &dodo, NOW);
            assert_eq!(result, Err(expected));
            assert_eq!(result.unwrap_err().message(), message);
            assert_eq!(engine.state(NOW), State::TrialEnded);
            assert_eq!(engine.stored, Stored::default());
        }
    }

    #[test]
    fn case_05_a_timeout_during_activation_saves_nothing() {
        let mut engine = trial_ended();
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        let error = activate(&mut engine, "KEY-PAID", &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::Unreachable);
        assert_eq!(
            error.message(),
            "OpenKlack couldn't reach the license service. Check your connection and try again."
        );
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert_eq!(engine.stored, Stored::default());
        assert_eq!(dodo.calls().len(), 1);
    }

    #[test]
    fn case_06_the_daily_check_runs_once_the_last_success_is_a_day_old() {
        let engine = licensed(25 * HOUR);
        assert!(engine.check_due(NOW));
        assert_eq!(engine.next_check_at(NOW), Some(NOW - HOUR));
        assert_eq!(engine.state(NOW), State::Licensed);
        let fresh = licensed(23 * HOUR);
        assert!(!fresh.check_due(NOW));
        assert_eq!(fresh.next_check_at(NOW), Some(NOW + HOUR));
        assert_eq!(unlicensed().next_check_at(NOW), None);
        assert_eq!(
            in_trial(DAY).next_check_at(NOW),
            None,
            "a trial never calls Dodo"
        );
    }

    #[test]
    fn case_07_a_timeout_two_days_in_keeps_sounds_on_during_grace() {
        let mut engine = licensed(2 * DAY);
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        assert_eq!(engine.check(&dodo, NOW), Err(LicenseError::Unreachable));
        assert_eq!(
            engine.state(NOW),
            State::Grace {
                days_offline: 2,
                days_left: 5
            }
        );
        assert!(engine.core_feature(NOW));
        assert_eq!(
            engine.stored.license.as_ref().unwrap().last_success_at,
            NOW - 2 * DAY
        );
        assert_eq!(engine.schedule.next_attempt_at, Some(NOW + MIN_BACKOFF));
    }

    #[test]
    fn case_08_a_timeout_after_eight_days_requires_a_check_and_stops_sounds() {
        let mut engine = licensed(8 * DAY);
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        assert_eq!(engine.check(&dodo, NOW), Err(LicenseError::Unreachable));
        assert_eq!(engine.state(NOW), State::CheckRequired);
        assert!(!engine.core_feature(NOW));
        assert!(
            engine.stored.license.is_some(),
            "a network failure never revokes"
        );
    }

    #[test]
    fn case_09_a_valid_answer_ends_check_required_and_updates_last_success() {
        let mut engine = licensed(8 * DAY);
        assert_eq!(engine.state(NOW), State::CheckRequired);
        let dodo = Fake::validating(true);
        assert_eq!(engine.check(&dodo, NOW), Ok(State::Licensed));
        assert_eq!(engine.stored.license.as_ref().unwrap().last_success_at, NOW);
        assert!(engine.core_feature(NOW));
        assert_eq!(
            dodo.calls(),
            vec![Call::Validate("KEY-PAID".into(), "lki_paid".into())]
        );
    }

    #[test]
    fn case_10_valid_false_revokes_and_stops_sounds() {
        let mut engine = licensed(HOUR);
        let dodo = Fake::validating(false);
        assert_eq!(engine.check(&dodo, NOW), Ok(State::Revoked));
        assert!(!engine.core_feature(NOW));
        assert!(engine.stored.license.as_ref().unwrap().revoked);
        // Checks continue daily, on the local clock: `valid: true` for this activation clears
        // the revocation.
        assert_eq!(engine.next_check_at(NOW), Some(NOW + DAY));
        assert_eq!(
            engine.check(&Fake::validating(true), NOW + DAY),
            Ok(State::Licensed)
        );
        assert!(!engine.stored.license.as_ref().unwrap().revoked);
    }

    #[test]
    fn case_11_a_clock_rolled_back_two_days_requires_a_check() {
        let engine = licensed(3 * DAY);
        let rolled_back = NOW - 3 * DAY - 2 * DAY;
        assert_eq!(engine.state(rolled_back), State::CheckRequired);
        assert!(!engine.core_feature(rolled_back));
        assert!(engine.check_due(rolled_back));
        // Within the tolerance the clock is trusted.
        assert_eq!(engine.state(NOW - 3 * DAY - HOUR / 2), State::Licensed);
    }

    #[test]
    fn case_13_a_registered_trial_past_three_days_ends_without_any_call() {
        let engine = in_trial(TRIAL_LENGTH + 60);
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert!(!engine.core_feature(NOW));
        assert_eq!(engine.next_check_at(NOW), None);
        assert_eq!(engine.next_registration_at(NOW), None);
        assert!(
            !engine.begin_registration(NOW, true),
            "not even when forced"
        );
        assert_eq!(engine.next_transition_at(NOW), None);
        // An unregistered trial that ran out has nothing to gain from the registry either.
        let engine = with_trial(unlicensed(), TRIAL_LENGTH + 60, false);
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert!(!engine.begin_registration(NOW, true));
    }

    #[test]
    fn case_14_a_clock_set_back_at_launch_holds_the_trial_until_corrected() {
        let mut engine = in_trial(2 * DAY);
        let rolled_back = NOW - 5 * DAY;
        engine.anchor_trial(rolled_back);
        engine.check_clock(rolled_back);
        assert_eq!(engine.state(rolled_back), State::ClockBehind);
        assert!(!engine.core_feature(rolled_back));
        assert!(engine.trial_frozen(rolled_back));
        assert_eq!(
            engine.observe(rolled_back + HOUR),
            Observed::default(),
            "nothing changes while the clock is behind"
        );
        assert_eq!(engine.next_transition_at(rolled_back), None);
        // Within the hour counts as corrected, and the hold added no time.
        // A corrected-looking clock only schedules an observation; the hold stays until then.
        assert!(engine.clock_corrected(NOW - HOUR / 2));
        assert_eq!(engine.state(NOW - HOUR / 2), State::ClockBehind);
        assert!(engine.trial_frozen(NOW - HOUR / 2));
        assert!(!engine.observe(NOW).trial);
        assert!(!engine.clock_behind);
        assert_eq!(engine.state(NOW), State::Trial { days_left: 1 });
        // Setting the clock back while the app runs is no hold: the time used stays used.
        assert_eq!(engine.state(rolled_back), State::Trial { days_left: 1 });
        // A license is never held by the trial's clock.
        let mut licensed = with_trial(licensed(HOUR), 2 * DAY, true);
        licensed.check_clock(rolled_back);
        assert!(!licensed.clock_behind);
    }

    #[test]
    fn case_28_elapsed_follows_monotonic_time_while_the_wall_clock_is_frozen_or_set_back() {
        let frozen = |mono: i64| Moment { wall: NOW, mono };
        let mut engine = in_trial(DAY);
        engine.anchor_trial(frozen(0));
        assert_eq!(engine.state(frozen(DAY)), State::Trial { days_left: 1 });
        assert!(engine.observe(frozen(DAY)).trial);
        assert_eq!(engine.next_transition_at(frozen(DAY)), Some(NOW + DAY));
        assert_eq!(engine.state(frozen(2 * DAY)), State::TrialEnded);
        assert_eq!(
            engine.state(Moment {
                wall: NOW - 5 * DAY,
                mono: 2 * DAY
            }),
            State::TrialEnded
        );
        // Observed twice at the same moment, the time counts once.
        let mut engine = in_trial(DAY);
        engine.anchor_trial(frozen(0));
        engine.observe(frozen(HOUR));
        engine.observe(frozen(HOUR));
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert_eq!(trial.last_seen_at, NOW + HOUR);
        // A wall clock ahead of the monotonic projection still counts.
        engine.observe(Moment {
            wall: NOW + 3 * HOUR,
            mono: 2 * HOUR,
        });
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert_eq!(trial.last_seen_at, NOW + 3 * HOUR);
    }

    #[test]
    fn case_31_records_from_the_old_trial_keys_are_not_licenses() {
        // The review's repro: a trial key activated four days ago, last checked a day ago.
        let json = format!(
            r#"{{"license":{{"license_key":"KEY-TRIAL","instance_id":"lki_trial","product_id":"pdt_openklack_trial","kind":"trial","activated_at":{},"last_success_at":{},"last_success_local":{},"last_observed_at":{},"event_seq":1}}}}"#,
            NOW - 4 * DAY,
            NOW - DAY,
            NOW - DAY,
            NOW - DAY
        );
        let stored: Stored = serde_json::from_str(&json).unwrap();
        assert_eq!(
            stored.license.as_ref().unwrap().kind.as_deref(),
            Some("trial")
        );
        let mut engine = Engine::new(stored.clone(), products());
        assert_eq!(engine.license(), None);
        assert_eq!(engine.state(NOW), State::Unlicensed, "not Licensed");
        assert!(!engine.core_feature(NOW));
        assert!(
            !engine
                .durable_state(&stored, &TrialSlot::Absent, NOW)
                .core_feature(),
            "nor through the saved-record gate"
        );
        assert_eq!(
            engine.begin_check(NOW, true),
            Ok(None),
            "never checked, so no paid grace"
        );
        assert_eq!(engine.next_check_at(NOW), None);
        // The trial rules apply from its own activation: already over, with nothing to gain.
        let trial = engine.provisional_trial(NOW).unwrap();
        assert_eq!(trial.started_at, NOW - 4 * DAY);
        engine.commit_trial(trial.clone(), NOW);
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert!(
            !engine
                .durable_state(&stored, &TrialSlot::Present(trial), NOW)
                .core_feature()
        );
        assert!(!engine.begin_registration(NOW, true));
        // Its slot can still be given back.
        assert_eq!(engine.begin_remove(NOW).unwrap().instance_id, "lki_trial");
        // No `kind`, but a product that isn't this app's paid one: the same.
        let other = Stored {
            license: Some(Record {
                product_id: X.into(),
                kind: None,
                ..stored.license.clone().unwrap()
            }),
            ..Stored::default()
        };
        let engine = Engine::new(other, products());
        assert_eq!(engine.license(), None);
        assert_eq!(engine.state(NOW), State::Unlicensed);
        // A record the trial-key era marked paid, for the paid product, is still a license.
        let paid: Stored = serde_json::from_str(&format!(
            r#"{{"license":{{"license_key":"K","instance_id":"i","product_id":"{P}","kind":"paid","activated_at":{NOW},"last_success_at":{NOW},"last_success_local":{NOW},"last_observed_at":{NOW},"event_seq":1}}}}"#
        ))
        .unwrap();
        let engine = Engine::new(paid, products());
        assert!(engine.license().is_some());
        assert_eq!(engine.state(NOW), State::Licensed);
    }

    #[test]
    fn a_registry_answer_is_held_while_the_clock_is_behind() {
        let mut engine = with_trial(unlicensed(), HOUR, false);
        let before = engine.trial.clone();
        let behind = Moment {
            wall: NOW - 2 * DAY,
            mono: 0,
        };
        engine.anchor_trial(behind);
        engine.check_clock(behind);
        let answer = RegistryAnswer {
            started_at: NOW - 10 * DAY,
            now: NOW,
        };
        assert_eq!(engine.finish_registration(Ok(answer), behind), Ok(false));
        assert_eq!(engine.trial, before, "nothing applied");
        assert!(engine.pending_registration.is_some());
        assert!(!engine.begin_registration(behind, true), "not asked again");
        let fixed = Moment {
            wall: NOW,
            mono: HOUR,
        };
        assert!(engine.observe(fixed).trial);
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert!(trial.registered);
        assert_eq!(trial.started_at, NOW - 10 * DAY - HOUR);
        assert_eq!(trial.last_seen_at, NOW);
        assert_eq!(engine.state(fixed), State::TrialEnded);
    }

    #[test]
    fn a_held_clock_behind_state_restricts_until_a_fresh_observation() {
        let mut engine = in_trial(71 * HOUR + 45 * 60);
        engine.anchor_trial(Moment { wall: NOW, mono: 0 });
        engine.check_clock(Moment {
            wall: NOW - 2 * HOUR,
            mono: 60,
        });
        assert!(engine.clock_behind);
        let saved = engine.trial.clone();
        for at in [
            Moment {
                wall: NOW,
                mono: 120,
            },
            Moment {
                wall: NOW - 30 * 60,
                mono: 120 + 30 * 60,
            },
        ] {
            assert!(engine.clock_corrected(at), "it looks right");
            assert_eq!(engine.state(at), State::ClockBehind, "but still held");
            assert_eq!(
                engine.durable_state(&Stored::default(), &saved, at),
                State::ClockBehind
            );
            assert!(engine.trial_frozen(at));
            assert_eq!(engine.next_transition_at(at), None);
            assert!(!engine.registration_wanted(at) || engine.trial_frozen(at));
        }
        // A still-behind observation keeps the hold; a corrected one ends it and re-anchors.
        assert_eq!(
            engine.observe(Moment {
                wall: NOW - 2 * HOUR,
                mono: 1_900
            }),
            Observed::default()
        );
        assert!(engine.clock_behind);
        let fixed = Moment {
            wall: NOW - 30 * 60,
            mono: 2_000,
        };
        engine.observe(fixed);
        assert!(!engine.clock_behind);
        assert_eq!(engine.trial_anchor.unwrap().mono, 2_000);
        assert_eq!(engine.state(fixed), State::Trial { days_left: 0 });
        // From here monotonic time counts again, whatever the wall clock does.
        assert_eq!(
            engine.state(Moment {
                wall: NOW - 30 * 60,
                mono: 2_000 + 15 * 60
            }),
            State::TrialEnded
        );
    }

    #[test]
    fn an_observation_sampled_before_a_newer_one_changes_nothing() {
        // The review's scenario in the engine: a tick samples (T, 0) and waits; a wake observes
        // (T + 2 h, 2 h); then the tick's stale sample arrives.
        let mut engine = with_trial(unlicensed(), 25 * HOUR, false);
        engine.anchor_trial(Moment { wall: NOW, mono: 0 });
        let wake = Moment {
            wall: NOW + 2 * HOUR,
            mono: 2 * HOUR,
        };
        engine.observe(wake);
        let (anchor, trial, behind) = (
            engine.trial_anchor,
            engine.trial.clone(),
            engine.clock_behind,
        );
        let stale = Moment { wall: NOW, mono: 0 };
        assert_eq!(engine.observe(stale), Observed::default());
        engine.check_clock(stale);
        engine.anchor_trial(stale);
        assert_eq!(engine.trial_anchor, anchor, "the anchor never moves back");
        assert_eq!(engine.trial, trial);
        assert_eq!(engine.clock_behind, behind);
        // The next wake, ten minutes on with a correct clock: no false hold, time counted once.
        let next = Moment {
            wall: NOW + 2 * HOUR + 600,
            mono: 2 * HOUR + 600,
        };
        engine.observe(next);
        engine.check_clock(next);
        assert!(!engine.clock_behind);
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert_eq!(trial.last_seen_at, NOW + 2 * HOUR + 600);
    }

    #[test]
    fn observations_out_of_order_never_move_time_back_count_it_twice_or_run_ahead() {
        for seed in 1..=20u64 {
            let mut state = seed;
            let mut next = |bound: i64| {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1_442_695_040_888_963_407);
                ((state >> 33) % bound.max(1) as u64) as i64
            };
            // Real moments: a correct wall clock that moves with monotonic time and sometimes
            // jumps ahead.
            let mut real = Vec::new();
            let (mut wall, mut mono) = (NOW, 0);
            for _ in 0..80 {
                let step = next(3 * HOUR);
                mono += step;
                wall += step;
                if next(10) == 0 {
                    wall += next(DAY);
                }
                real.push(Moment { wall, mono });
            }
            let mut engine = in_trial(HOUR);
            engine.anchor_trial(Moment { wall: NOW, mono: 0 });
            let (mut last_seen, mut last_anchor) = (NOW, 0);
            let (mut max_wall, mut max_mono) = (NOW, 0);
            for (index, moment) in real.iter().enumerate() {
                // Each moment arrives, sometimes with an older sample delivered after it.
                let mut batch = vec![*moment];
                if index > 0 && next(2) == 0 {
                    batch.push(real[next(index as i64) as usize]);
                }
                if next(3) == 0 {
                    batch.reverse();
                }
                for at in batch {
                    engine.observe(at);
                    if next(2) == 0 {
                        engine.check_clock(at);
                    }
                    max_wall = max_wall.max(at.wall);
                    max_mono = max_mono.max(at.mono);
                    let TrialSlot::Present(trial) = &engine.trial else {
                        panic!()
                    };
                    let anchor = engine.trial_anchor.unwrap();
                    assert!(
                        trial.last_seen_at >= last_seen,
                        "seed {seed}: time went back"
                    );
                    assert!(
                        trial.last_seen_at <= max_wall.max(NOW + max_mono),
                        "seed {seed}: counted twice or ahead of real time"
                    );
                    assert!(anchor.mono >= last_anchor, "seed {seed}: anchor moved back");
                    assert!(
                        !engine.clock_behind,
                        "seed {seed}: a correct clock was held"
                    );
                    (last_seen, last_anchor) = (trial.last_seen_at, anchor.mono);
                }
            }
        }
    }

    #[test]
    fn case_15_the_trial_end_is_a_deadline_on_the_local_clock() {
        let engine = in_trial(TRIAL_LENGTH - 60);
        assert_eq!(engine.state(NOW), State::Trial { days_left: 0 });
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + 60));
        assert_eq!(engine.state(NOW + 59), State::Trial { days_left: 0 });
        assert_eq!(engine.state(NOW + 60), State::TrialEnded);
        assert!(!engine.core_feature(NOW + 60));
        assert_eq!(engine.next_transition_at(NOW + 60), None);
    }

    #[test]
    fn case_20_an_unregistered_trial_stops_at_the_offline_limit_until_the_registry_answers() {
        let mut engine = with_trial(unlicensed(), 0, false);
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + DAY));
        assert_eq!(engine.state(NOW + 23 * HOUR), State::Trial { days_left: 3 });
        assert_eq!(engine.state(NOW + DAY), State::TrialOffline);
        assert!(!engine.core_feature(NOW + 25 * HOUR));
        assert!(engine.begin_registration(NOW + 25 * HOUR, true));
        // The registry has the same start: 25 hours used, two days (rounded up) left.
        let answer = Ok(RegistryAnswer {
            started_at: NOW,
            now: NOW + 25 * HOUR,
        });
        assert_eq!(
            engine.finish_registration(answer, NOW + 25 * HOUR),
            Ok(true)
        );
        assert_eq!(engine.state(NOW + 25 * HOUR), State::Trial { days_left: 2 });
        assert_eq!(
            engine.next_transition_at(NOW + 25 * HOUR),
            Some(NOW + TRIAL_LENGTH)
        );
    }

    #[test]
    fn case_21_registry_rate_limits_hold_and_errors_back_off_without_changing_state() {
        let mut engine = with_trial(unlicensed(), HOUR, false);
        let limited = FakeRegistry::answering(Err(RegistryError::RateLimited { retry_after: 120 }));
        assert_eq!(
            engine.register(&limited, NOW),
            Err(RegistryError::RateLimited { retry_after: 120 })
        );
        assert_eq!(engine.state(NOW), State::Trial { days_left: 3 });
        assert_eq!(engine.next_registration_at(NOW), Some(NOW + 120));
        assert_eq!(engine.register(&limited, NOW + 119), Ok(None));
        assert!(
            !engine.begin_registration(NOW + 119, true),
            "a forced attempt waits too"
        );
        assert_eq!(limited.calls(), 1, "no registry call for 120 s");
        assert!(engine.register(&limited, NOW + 120).is_err());
        assert_eq!(limited.calls(), 2);
        // `500`: backoff from a minute, doubling, capped at an hour.
        let mut engine = with_trial(unlicensed(), HOUR, false);
        let failing = FakeRegistry::answering(Err(RegistryError::Unexpected("500".into())));
        let mut now = NOW;
        let mut waits = Vec::new();
        for _ in 0..9 {
            assert!(engine.register(&failing, now).is_err());
            assert_eq!(engine.register(&failing, now + 1), Ok(None));
            let next = engine.next_registration_at(now).unwrap();
            waits.push(next - now);
            now = next;
        }
        assert_eq!(waits, vec![60, 120, 240, 480, 960, 1920, 3600, 3600, 3600]);
        assert_eq!(failing.calls(), 9);
        let trial = with_trial(unlicensed(), HOUR, false).trial;
        assert_eq!(engine.trial, trial, "the trial record is unchanged");
        assert!(!engine.registration.network_down);
    }

    #[test]
    fn case_22_removing_this_mac_after_the_trial_ended_returns_to_trial_ended() {
        let mut engine = with_trial(licensed(HOUR), TRIAL_LENGTH + DAY, true);
        let trial = engine.trial.clone();
        assert_eq!(engine.state(NOW), State::Licensed);
        let dodo = Fake::default();
        assert_eq!(engine.remove(&dodo, NOW), Ok(State::TrialEnded));
        assert_eq!(engine.stored, Stored::default());
        assert_eq!(engine.trial, trial, "the trial record is unchanged");
        assert_eq!(
            dodo.calls(),
            vec![Call::Deactivate("KEY-PAID".into(), "lki_paid".into())]
        );
        assert!(!engine.core_feature(NOW));
    }

    #[test]
    fn case_23_removing_this_mac_with_trial_time_left_returns_to_the_trial() {
        let mut engine = with_trial(licensed(HOUR), 2 * DAY, true);
        assert_eq!(
            engine.remove(&Fake::default(), NOW),
            Ok(State::Trial { days_left: 1 })
        );
        assert!(engine.core_feature(NOW));
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + DAY));
        assert!(!engine.begin_registration(NOW, true), "already registered");
    }

    #[test]
    fn case_24_removing_this_mac_offline_keeps_the_license_and_asks_to_retry() {
        let mut engine = with_trial(licensed(HOUR), TRIAL_LENGTH + DAY, true);
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        let error = engine.remove(&dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::RemoveOffline);
        assert!(error.message().contains("try again"));
        assert_eq!(engine.state(NOW), State::Licensed);
        assert!(engine.stored.license.is_some());
    }

    #[test]
    fn case_25_a_rate_limit_holds_every_call_for_retry_after_and_changes_nothing() {
        let rate_limited = DodoError::RateLimited { retry_after: 60 };
        // Licensed: the check is held and the state is unchanged.
        let mut engine = licensed(25 * HOUR);
        let dodo = Fake::failing(rate_limited.clone());
        assert_eq!(
            engine.check(&dodo, NOW),
            Err(LicenseError::RateLimited { retry_after: 60 })
        );
        assert_eq!(engine.state(NOW), State::Licensed);
        assert_eq!(engine.next_check_at(NOW), Some(NOW + 60));
        assert!(!engine.check_due(NOW + 59));
        assert_eq!(
            engine.check(&dodo, NOW + 30),
            Err(LicenseError::RateLimited { retry_after: 30 })
        );
        assert_eq!(dodo.calls().len(), 1, "no call for 60 s");
        assert!(engine.check_due(NOW + 60));
        assert_eq!(
            engine.check(&Fake::validating(true), NOW + 60),
            Ok(State::Licensed)
        );
        // Trial ended: activation is held the same way.
        let mut engine = trial_ended();
        let dodo = Fake::failing(rate_limited);
        assert_eq!(
            activate(&mut engine, "KEY", &dodo, NOW),
            Err(LicenseError::RateLimited { retry_after: 60 })
        );
        assert_eq!(
            activate(&mut engine, "KEY", &dodo, NOW + 10),
            Err(LicenseError::RateLimited { retry_after: 50 })
        );
        assert_eq!(dodo.calls().len(), 1);
        assert_eq!(engine.stored, Stored::default());
        assert_eq!(engine.state(NOW + 10), State::TrialEnded);
    }

    #[test]
    fn case_27_device_hashes_differ_per_app_and_never_contain_the_hardware_uuid() {
        let uuid = "00000000-1111-2222-3333-444444444444";
        let openklack = device_hash("openklack", uuid);
        let openreaction = device_hash("openreaction", uuid);
        assert_ne!(openklack, openreaction);
        for hash in [&openklack, &openreaction] {
            assert_ne!(hash.as_str(), uuid);
            assert!(!hash.contains(uuid));
            assert_eq!(hash.len(), 64);
            assert!(
                hash.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            );
        }
        // `printf 'openapps-trial-v1:openklack:<uuid>' | shasum -a 256`
        assert_eq!(
            openklack,
            "97a89ea0b23e771bc9038fac3d9b1359a7033eee688f71f46f2e76b81ae41f48"
        );
        assert_eq!(
            openreaction,
            "3908da30d9e234cb79e2610af64dae33d48e104abf20dc631670ce3fcdcbc2d7"
        );
        assert_eq!(device_hash(APP_ID, uuid), openklack);
    }

    #[test]
    fn registration_adopts_the_earlier_start_and_never_calls_again() {
        // The registry remembers an earlier start: it wins.
        let mut engine = with_trial(unlicensed(), 0, false);
        let registry = FakeRegistry::answering(registry_start(DAY));
        assert_eq!(
            engine.register(&registry, NOW),
            Ok(Some(State::Trial { days_left: 2 }))
        );
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!("the trial record is kept");
        };
        assert!(trial.registered);
        assert_eq!(trial.started_at, NOW - DAY);
        assert_eq!(engine.register(&registry, NOW + DAY), Ok(None));
        assert_eq!(registry.calls(), 1, "a registered trial never calls again");
        // The registry's start is converted by its own clock, not compared with the Mac's.
        let mut engine = with_trial(unlicensed(), 0, false);
        let skewed = FakeRegistry::answering(Ok(RegistryAnswer {
            started_at: NOW + 5 * DAY - 2 * HOUR,
            now: NOW + 5 * DAY,
        }));
        engine.register(&skewed, NOW).unwrap();
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert_eq!(trial.started_at, NOW - 2 * HOUR);
        // A later registry start never moves the provisional start forward.
        let mut engine = with_trial(unlicensed(), 3 * HOUR, false);
        engine
            .register(&FakeRegistry::answering(registry_start(0)), NOW)
            .unwrap();
        let TrialSlot::Present(trial) = &engine.trial else {
            panic!()
        };
        assert_eq!(trial.started_at, NOW - 3 * HOUR);
        assert!(trial.registered);
        // A license in the way: the trial record is ignored and nothing is asked.
        let engine = with_trial(licensed(HOUR), 0, false);
        assert!(!engine.begin_registration(NOW, true));
        // An unread or absent trial has nothing to register either.
        let mut engine = unlicensed();
        assert!(!engine.begin_registration(NOW, true));
        engine.trial = TrialSlot::Unread;
        assert!(!engine.begin_registration(NOW, true));
        assert_eq!(
            engine.provisional_trial(NOW),
            None,
            "never over an unread record"
        );
        assert_eq!(engine.state(NOW), State::Unlicensed);
    }

    #[test]
    fn a_provisional_trial_starts_only_without_a_license_and_over_an_absent_record() {
        let mut engine = unlicensed();
        assert_eq!(engine.state(NOW), State::Unlicensed);
        assert!(!engine.core_feature(NOW), "not until the record is saved");
        let trial = engine.provisional_trial(NOW).unwrap();
        assert_eq!(trial, TrialRecord::provisional(NOW, NOW));
        assert!(!trial.registered);
        engine.commit_trial(trial, NOW);
        assert_eq!(engine.state(NOW), State::Trial { days_left: 3 });
        assert_eq!(engine.provisional_trial(NOW), None);
        assert_eq!(licensed(HOUR).provisional_trial(NOW), None);
        assert!(engine.begin_registration(NOW, false), "asked at once");
    }

    #[test]
    fn trial_days_round_up_and_the_last_day_says_less_than_a_day() {
        for (elapsed, state) in [
            (0, State::Trial { days_left: 3 }),
            (HOUR, State::Trial { days_left: 3 }),
            (DAY, State::Trial { days_left: 2 }),
            (DAY + 1, State::Trial { days_left: 2 }),
            (2 * DAY, State::Trial { days_left: 1 }),
            (2 * DAY + 1, State::Trial { days_left: 0 }),
            (TRIAL_LENGTH - 1, State::Trial { days_left: 0 }),
            (TRIAL_LENGTH, State::TrialEnded),
        ] {
            assert_eq!(in_trial(elapsed).state(NOW), state, "after {elapsed} s");
        }
        // A start in the future counts as no time used.
        let mut engine = in_trial(0);
        engine.trial = TrialSlot::Present(TrialRecord {
            started_at: NOW + 10 * DAY,
            last_seen_at: NOW,
            registered: true,
            device_id: None,
        });
        assert_eq!(engine.state(NOW), State::Trial { days_left: 3 });
        // A shortened debug trial keeps an offline limit of its own.
        let terms = TrialTerms::shortened(600);
        assert_eq!(
            terms,
            TrialTerms {
                length: 600,
                offline_limit: 200
            }
        );
        assert_eq!(TrialTerms::shortened(10 * DAY), TrialTerms::default());
    }

    #[test]
    fn a_licensed_mac_ignores_but_keeps_the_trial_record() {
        let mut engine = with_trial(licensed(HOUR), TRIAL_LENGTH + DAY, false);
        assert_eq!(engine.state(NOW), State::Licensed);
        assert_eq!(
            engine.next_transition_at(NOW),
            Some(NOW - HOUR + GRACE_WARNING_AFTER)
        );
        assert!(engine.observe(NOW + 60).trial, "last_seen_at still rises");
        let revoked = {
            engine.check(&Fake::validating(false), NOW + 60).unwrap();
            engine.state(NOW + 60)
        };
        assert_eq!(revoked, State::Revoked, "not the trial's state");
        assert!(matches!(engine.trial, TrialSlot::Present(_)));
    }

    #[test]
    fn failed_checks_back_off_from_a_minute_to_an_hour_then_daily() {
        let mut engine = licensed(25 * HOUR);
        let dodo = Fake::failing(DodoError::Offline("down".into()));
        let mut now = NOW;
        let mut waits = Vec::new();
        for _ in 0..9 {
            assert!(engine.check_due(now));
            assert!(engine.check(&dodo, now).is_err());
            let next = engine.next_check_at(now).unwrap();
            waits.push(next - now);
            now = next;
        }
        assert_eq!(waits, vec![60, 120, 240, 480, 960, 1920, 3600, DAY, DAY]);
        assert!(engine.core_feature(NOW), "still inside the grace period");
    }

    #[test]
    fn grace_warns_only_after_five_days_offline() {
        let mut engine = licensed(5 * DAY + HOUR);
        let dodo = Fake::failing(DodoError::Offline("down".into()));
        assert!(engine.check(&dodo, NOW).is_err());
        assert_eq!(
            engine.state(NOW),
            State::Grace {
                days_offline: 5,
                days_left: 2
            }
        );
    }

    #[test]
    fn stale_answers_for_a_replaced_or_removed_activation_change_nothing() {
        let mut engine = licensed(HOUR);
        let old_probe = engine.begin_check(NOW, true).unwrap().unwrap();
        assert_eq!(old_probe.instance_id, "lki_paid");
        // The user enters another key while the old activation's check is in flight.
        assert_eq!(
            activate(&mut engine, "KEY-PAID-2", &Fake::activating(P), NOW),
            Ok(State::Licensed)
        );
        let late_false = Ok(Validation {
            valid: false,
            server_time: Some(NOW + 10),
        });
        assert_eq!(
            engine.finish_check(&old_probe, late_false, NOW + 10),
            Ok(State::Licensed)
        );
        let record = engine.stored.license.as_ref().unwrap();
        assert!(
            !record.revoked,
            "a late `false` for the old activation must not revoke the new key"
        );
        assert_eq!(record.last_success_at, NOW);
        let late_true = Ok(Validation {
            valid: true,
            server_time: Some(NOW + 20),
        });
        engine
            .finish_check(&old_probe, late_true, NOW + 20)
            .unwrap();
        assert_eq!(engine.stored.license.as_ref().unwrap().last_success_at, NOW);
        // A late failure for the old activation must not touch the retry schedule either.
        let schedule = engine.schedule.clone();
        engine
            .finish_check(&old_probe, Err(DodoError::Offline("late".into())), NOW + 30)
            .unwrap();
        assert_eq!(engine.schedule, schedule);
        // Removal: a late `true` for the removed activation must not resurrect it.
        let paid_probe = engine.begin_check(NOW + DAY + 1, false).unwrap().unwrap();
        assert_eq!(
            engine.remove(&Fake::default(), NOW + DAY + 1),
            Ok(State::Unlicensed)
        );
        let late_true = Ok(Validation {
            valid: true,
            server_time: None,
        });
        assert_eq!(
            engine.finish_check(&paid_probe, late_true, NOW + DAY + 2),
            Ok(State::Unlicensed)
        );
        assert!(engine.stored.license.is_none());
        assert_eq!(engine.begin_check(NOW + DAY + 2, true), Ok(None));
    }

    #[test]
    fn revocation_is_stored_and_survives_an_offline_restart() {
        let mut engine = licensed(HOUR);
        assert_eq!(
            engine.check(&Fake::validating(false), NOW),
            Ok(State::Revoked)
        );
        let json = serde_json::to_string(&engine.stored).unwrap();
        let restarted = Engine::new(serde_json::from_str(&json).unwrap(), products());
        // Well inside what would have been the grace window, and with no network.
        assert_eq!(restarted.state(NOW + DAY), State::Revoked);
        assert!(!restarted.core_feature(NOW + DAY));
        assert_eq!(restarted.next_transition_at(NOW + DAY), None);
        assert!(restarted.begin_check(NOW + DAY, true).unwrap().is_some());
        // Only a new activation clears it, and the new record starts clean.
        let mut restarted = restarted;
        assert_eq!(
            activate(
                &mut restarted,
                "KEY-PAID-2",
                &Fake::activating(P),
                NOW + DAY
            ),
            Ok(State::Licensed)
        );
        assert!(!restarted.stored.license.as_ref().unwrap().revoked);
    }

    #[test]
    fn deadlines_flip_state_on_time_while_network_calls_are_held() {
        // Paid: a two-hour rate limit must not delay the end of grace an hour away.
        let mut engine = licensed(GRACE_PERIOD - HOUR);
        let dodo = Fake::failing(DodoError::RateLimited { retry_after: 7200 });
        assert!(engine.check(&dodo, NOW).is_err());
        assert_eq!(engine.next_check_at(NOW), Some(NOW + 7200));
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + HOUR));
        assert_eq!(engine.state(NOW), State::Licensed);
        assert_eq!(engine.state(NOW + HOUR + 1), State::CheckRequired);
        assert!(!engine.core_feature(NOW + HOUR + 1));
        // The five-day warning is a deadline too.
        let engine = licensed(GRACE_WARNING_AFTER - 60);
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + 60));
        // Trial: the offline limit arrives regardless of a registry hold.
        let mut engine = with_trial(unlicensed(), DAY - 60, false);
        let limited =
            FakeRegistry::answering(Err(RegistryError::RateLimited { retry_after: 7200 }));
        assert!(engine.register(&limited, NOW).is_err());
        assert_eq!(engine.next_registration_at(NOW), Some(NOW + 7200));
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + 60));
        assert_eq!(engine.state(NOW + 60), State::TrialOffline);
    }

    #[test]
    fn a_server_error_backs_off_without_calling_the_network_down() {
        let mut engine = licensed(25 * HOUR);
        assert!(
            engine
                .check(&Fake::failing(DodoError::ServerError(503)), NOW)
                .is_err()
        );
        assert!(!engine.schedule.network_down);
        assert_eq!(
            engine.state(NOW),
            State::Grace {
                days_offline: 1,
                days_left: 6
            }
        );
        assert!(
            engine
                .check(
                    &Fake::failing(DodoError::Offline("timed out".into())),
                    NOW + 60
                )
                .is_err()
        );
        assert!(engine.schedule.network_down);
        assert_eq!(
            engine.check(&Fake::validating(true), NOW + 180),
            Ok(State::Licensed)
        );
        assert!(!engine.schedule.network_down);
        // The registry keeps its own notion of the network being down.
        let mut engine = with_trial(unlicensed(), 0, false);
        let offline = FakeRegistry::answering(Err(RegistryError::Offline("no connection".into())));
        assert!(engine.register(&offline, NOW).is_err());
        assert!(engine.registration.network_down);
        assert!(!engine.schedule.network_down);
    }

    #[test]
    fn an_activation_that_cannot_be_saved_is_abandoned_and_the_old_one_kept() {
        let mut engine = licensed(HOUR);
        let before = engine.stored.clone();
        let dodo = Fake::activating(P);
        let activated = engine.activate("KEY-PAID-2", &dodo, NOW).unwrap();
        assert_eq!(
            engine.stored, before,
            "nothing changes before the record is saved"
        );
        assert_eq!(
            activated.replaced,
            Some(Probe {
                license_key: "KEY-PAID".into(),
                instance_id: "lki_paid".into()
            })
        );
        assert_eq!(dodo.calls().len(), 1, "the old one is not deactivated yet");
        // Saving failed: give the new slot back, keep the old activation.
        engine.abandon_activation(activated, &dodo, NOW);
        assert_eq!(engine.stored, before);
        assert_eq!(engine.state(NOW), State::Licensed);
        assert_eq!(
            dodo.calls()[1],
            Call::Deactivate("KEY-PAID-2".into(), "lki_pdt_openklack".into())
        );
        // If even that fails, the slot is remembered and freed later.
        let activated = engine.activate("KEY-PAID-2", &dodo, NOW).unwrap();
        let down = Fake::failing(DodoError::Offline("down".into()));
        engine.abandon_activation(activated, &down, NOW);
        assert_eq!(engine.stored.license, before.license);
        assert_eq!(engine.stored.pending_cleanups.len(), 1);
        assert!(engine.release_cleanups(&Fake::default(), NOW + 60));
        assert!(engine.stored.pending_cleanups.is_empty());
    }

    #[test]
    fn replacing_a_paid_activation_frees_the_old_slot_or_remembers_it() {
        let mut engine = licensed(HOUR);
        let dodo = Fake::activating(P);
        dodo.deactivate
            .borrow_mut()
            .push(Err(DodoError::Offline("down".into())));
        assert_eq!(
            activate(&mut engine, "KEY-PAID-2", &dodo, NOW),
            Ok(State::Licensed)
        );
        assert_eq!(
            engine.stored.license.as_ref().unwrap().license_key,
            "KEY-PAID-2"
        );
        assert_eq!(
            dodo.calls()[1],
            Call::Deactivate("KEY-PAID".into(), "lki_paid".into())
        );
        assert_eq!(
            engine.stored.pending_cleanups,
            vec![Probe {
                license_key: "KEY-PAID".into(),
                instance_id: "lki_paid".into()
            }]
        );
        // Still offline: nothing is dropped. Back online: freed and forgotten.
        assert!(
            !engine.release_cleanups(&Fake::failing(DodoError::Offline("down".into())), NOW + 60)
        );
        assert_eq!(engine.stored.pending_cleanups.len(), 1);
        let later = Fake::default();
        assert!(engine.release_cleanups(&later, NOW + 120));
        assert!(engine.stored.pending_cleanups.is_empty());
        assert_eq!(
            later.calls(),
            vec![Call::Deactivate("KEY-PAID".into(), "lki_paid".into())]
        );
        // A refused key whose slot could not be given back is remembered the same way.
        let mut engine = unlicensed();
        let dodo = Fake::activating(X);
        dodo.deactivate
            .borrow_mut()
            .push(Err(DodoError::Offline("down".into())));
        assert!(engine.activate("KEY-X", &dodo, NOW).is_err());
        assert!(engine.stored.license.is_none());
        assert_eq!(
            engine.stored.pending_cleanups[0].instance_id,
            "lki_pdt_openreaction"
        );
        // The stored shape keeps the list.
        let json = serde_json::to_string(&engine.stored).unwrap();
        assert_eq!(
            serde_json::from_str::<Stored>(&json).unwrap(),
            engine.stored
        );
    }

    #[test]
    fn odd_answers_back_off_and_remove_honours_retry_after() {
        let mut engine = licensed(25 * HOUR);
        let odd = Fake::failing(DodoError::Unexpected("html".into()));
        assert_eq!(engine.check(&odd, NOW), Err(LicenseError::Unreachable));
        assert_eq!(
            engine.state(NOW),
            State::Grace {
                days_offline: 1,
                days_left: 6
            }
        );
        assert!(!engine.check_due(NOW + 30), "no immediate retry loop");
        assert_eq!(engine.next_check_at(NOW), Some(NOW + MIN_BACKOFF));
        assert!(!engine.stored.license.as_ref().unwrap().revoked);
        // Rate limited: Remove this Mac waits too, and keeps the record.
        let limited = Fake::failing(DodoError::RateLimited { retry_after: 60 });
        assert!(engine.check(&limited, NOW + 60).is_err());
        let dodo = Fake::default();
        assert_eq!(
            engine.remove(&dodo, NOW + 70),
            Err(LicenseError::RemoveOffline)
        );
        assert!(dodo.calls().is_empty());
        assert!(engine.stored.license.is_some());
        assert!(!engine.release_cleanups(&dodo, NOW + 70));
        assert_eq!(engine.remove(&dodo, NOW + 121), Ok(State::Unlicensed));
    }

    #[test]
    fn freeing_slots_honours_rate_limits_and_holds_are_bounded_to_a_day() {
        let mut engine = licensed(HOUR);
        let limited = Fake::failing(DodoError::RateLimited { retry_after: 120 });
        let activated = engine
            .activate("KEY-PAID-2", &Fake::activating(P), NOW)
            .unwrap();
        // The old slot's deactivation is rate limited: remembered, and nothing else is called
        // until the hold passes, including a refused key's slot.
        assert_eq!(engine.commit(activated, &limited, NOW), State::Licensed);
        assert_eq!(engine.stored.pending_cleanups.len(), 1);
        assert_eq!(engine.schedule.hold_until, Some(NOW + 120));
        let refused = Fake::activating(X);
        assert!(engine.activate("KEY-X", &refused, NOW + 10).is_err());
        assert!(
            refused.calls().is_empty(),
            "held: not even the activation call"
        );
        assert!(!engine.release_cleanups(&refused, NOW + 10));
        assert!(refused.calls().is_empty());
        assert_eq!(engine.stored.pending_cleanups.len(), 1);
        assert!(engine.release_cleanups(&Fake::default(), NOW + 120));
        assert!(engine.stored.pending_cleanups.is_empty());
        // A hold never exceeds a day, and never rounds down to nothing.
        engine.note_rate_limit(NOW, 10 * DAY);
        assert_eq!(engine.schedule.hold_until, Some(NOW + DAY));
        engine.note_rate_limit(NOW, -5);
        assert_eq!(engine.schedule.hold_until, Some(NOW + 1));
    }

    #[test]
    fn a_removal_answer_for_another_activation_is_ignored() {
        let mut engine = licensed(HOUR);
        let old = engine.begin_remove(NOW).unwrap();
        assert_eq!(
            activate(&mut engine, "KEY-PAID-2", &Fake::activating(P), NOW),
            Ok(State::Licensed)
        );
        assert_eq!(engine.finish_remove(&old, Ok(()), NOW), Ok(State::Licensed));
        assert_eq!(
            engine.stored.license.as_ref().unwrap().license_key,
            "KEY-PAID-2"
        );
    }

    #[test]
    fn a_failed_launch_check_retries_with_backoff_instead_of_waiting_a_day() {
        let mut engine = licensed(HOUR);
        assert!(!engine.check_due(NOW));
        assert!(
            engine
                .check(&Fake::failing(DodoError::Offline("down".into())), NOW)
                .is_err()
        );
        assert_eq!(engine.next_check_at(NOW), Some(NOW + MIN_BACKOFF));
        assert_eq!(engine.state(NOW), State::Licensed);
        assert_eq!(
            engine.check(&Fake::validating(true), NOW + MIN_BACKOFF),
            Ok(State::Licensed)
        );
        // Back on the daily schedule, a day after the answer on the local clock.
        assert_eq!(
            engine.next_check_at(NOW + MIN_BACKOFF),
            Some(NOW + MIN_BACKOFF + DAY)
        );
    }

    #[test]
    fn the_schedule_runs_on_the_local_clock_whatever_the_server_offset() {
        // The Mac is two days ahead of Dodo: a fresh success must not be due again at once.
        let mut engine = licensed(0);
        let local = NOW + 2 * DAY;
        let dodo = Fake::default();
        dodo.validate.borrow_mut().push(Ok(Validation {
            valid: true,
            server_time: Some(NOW),
        }));
        assert_eq!(engine.check(&dodo, local), Ok(State::Licensed));
        assert!(!engine.check_due(local));
        assert!(!engine.check_due(local + DAY - 1));
        assert!(engine.check_due(local + DAY));
        // A revoked record is on the daily schedule too, not immediately due again.
        assert_eq!(
            engine.check(&Fake::validating(false), local + DAY),
            Ok(State::Revoked)
        );
        assert!(!engine.check_due(local + DAY + 1));
        assert_eq!(engine.next_check_at(local + DAY), Some(local + 2 * DAY));
    }

    #[test]
    fn authoritative_changes_advance_the_event_sequence() {
        let mut engine = unlicensed();
        assert_eq!(
            activate(&mut engine, "KEY-PAID", &Fake::activating(P), NOW),
            Ok(State::Licensed)
        );
        assert_eq!(engine.stored.license.as_ref().unwrap().event_seq, 1);
        engine.check(&Fake::validating(true), NOW + DAY).unwrap();
        assert_eq!(engine.stored.license.as_ref().unwrap().event_seq, 2);
        engine
            .check(&Fake::validating(false), NOW + 2 * DAY)
            .unwrap();
        assert_eq!(engine.stored.license.as_ref().unwrap().event_seq, 3);
        // Answers for another activation, or no answer, leave it alone.
        let probe = Probe {
            license_key: "KEY-PAID".into(),
            instance_id: "other".into(),
        };
        engine
            .finish_check(
                &probe,
                Ok(Validation {
                    valid: true,
                    server_time: None,
                }),
                NOW + 3 * DAY,
            )
            .unwrap();
        assert!(
            engine
                .check(
                    &Fake::failing(DodoError::Offline("down".into())),
                    NOW + 3 * DAY
                )
                .is_err()
        );
        assert_eq!(engine.stored.license.as_ref().unwrap().event_seq, 3);
        // A record without the field is at sequence zero, so any journal entry outranks it.
        let legacy: Stored = serde_json::from_str(
            r#"{"license":{"license_key":"K","instance_id":"i","product_id":"p","kind":"paid","activated_at":1,"last_success_at":1}}"#,
        )
        .unwrap();
        assert_eq!(legacy.license.unwrap().event_seq, 0);
    }

    #[test]
    fn an_untrusted_clock_forces_a_check_even_with_one_scheduled() {
        let mut engine = licensed(HOUR);
        assert_eq!(
            engine.check(&Fake::validating(true), NOW),
            Ok(State::Licensed)
        );
        assert_eq!(engine.next_check_at(NOW), Some(NOW + DAY));
        // The clock jumps back two days: the scheduled attempt no longer applies.
        engine.observe(NOW + HOUR);
        assert!(engine.check_due(NOW - 2 * DAY));
        assert_eq!(engine.next_check_at(NOW - 2 * DAY), Some(NOW - 2 * DAY));
        // A rate limit still holds.
        engine.note_rate_limit(NOW - 2 * DAY, 60);
        assert_eq!(
            engine.next_check_at(NOW - 2 * DAY),
            Some(NOW - 2 * DAY + 60)
        );
        // One forced attempt fails: the backoff decides from there, not every second.
        let rolled = NOW - 2 * DAY + 60;
        assert!(
            engine
                .check(&Fake::failing(DodoError::Offline("down".into())), rolled)
                .is_err()
        );
        assert!(!engine.check_due(rolled + 1));
        assert_eq!(engine.next_check_at(rolled), Some(rolled + MIN_BACKOFF));
    }

    #[test]
    fn the_stored_records_round_trip_and_tolerate_older_shapes() {
        let stored = Stored {
            license: Some(Record {
                license_key: "KEY".into(),
                instance_id: "lki".into(),
                product_id: P.into(),
                kind: None,
                activated_at: NOW,
                last_success_at: NOW,
                last_success_local: NOW,
                last_observed_at: NOW,
                revoked: false,
                event_seq: 1,
            }),
            pending_cleanups: vec![],
        };
        let json = serde_json::to_string(&stored).unwrap();
        assert_eq!(serde_json::from_str::<Stored>(&json).unwrap(), stored);
        assert_eq!(
            serde_json::from_str::<Stored>("{}").unwrap(),
            Stored::default()
        );
        // Fields from the trial-key era are ignored.
        assert_eq!(
            serde_json::from_str::<Stored>(r#"{"trial_used":true}"#).unwrap(),
            Stored::default()
        );
        let trial = TrialRecord {
            started_at: NOW,
            last_seen_at: NOW + HOUR,
            registered: true,
            device_id: None,
        };
        let json = serde_json::to_string(&trial).unwrap();
        assert_eq!(
            json,
            format!(
                r#"{{"started_at":{NOW},"last_seen_at":{},"registered":true}}"#,
                NOW + HOUR
            )
        );
        assert_eq!(serde_json::from_str::<TrialRecord>(&json).unwrap(), trial);
        let fallback = TrialRecord {
            device_id: Some("random".into()),
            ..trial
        };
        let json = serde_json::to_string(&fallback).unwrap();
        assert_eq!(
            serde_json::from_str::<TrialRecord>(&json).unwrap(),
            fallback
        );
        assert!(
            serde_json::from_str::<TrialRecord>("{}").is_err(),
            "a record without its fields is unreadable, not a fresh trial"
        );
    }
}
