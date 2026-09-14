//! The licensing rules from LICENSING.md, with no clock, network or Keychain of their own.
//! Time is Unix seconds passed in by the caller; Dodo is a trait so tests script every answer.

use serde::{Deserialize, Serialize};

pub const DAY: i64 = 86_400;
pub const CHECK_INTERVAL: i64 = DAY;
pub const GRACE_PERIOD: i64 = 7 * DAY;
pub const GRACE_WARNING_AFTER: i64 = 5 * DAY;
pub const TRIAL_LENGTH: i64 = 3 * DAY;
pub const CLOCK_ROLLBACK_TOLERANCE: i64 = 3600;
pub const MIN_BACKOFF: i64 = 60;
pub const MAX_BACKOFF: i64 = 3600;
/// The longest `Retry-After` honoured; anything larger is treated as a day.
pub const MAX_HOLD: i64 = DAY;
pub const ACTIVATION_NAME: &str = "Mac";
pub const APP_NAME: &str = "OpenKlack";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Paid,
    Trial,
}

/// The Keychain record for one activation of this Mac.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub license_key: String,
    pub instance_id: String,
    pub product_id: String,
    pub kind: Kind,
    /// Activation `created_at`, server time.
    pub activated_at: i64,
    /// Time of the last `valid: true` or activation, from the response `Date` header.
    pub last_success_at: i64,
    /// The latest local time seen while this record was active; a rolled-back clock cannot
    /// extend a trial past it.
    #[serde(default)]
    pub seen_at: i64,
    /// Set by `valid: false` for this activation; only a new activation clears it.
    #[serde(default)]
    pub revoked: bool,
}

/// Everything kept in the single Keychain item. `trial_used` survives removing the record.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Stored {
    #[serde(default)]
    pub trial_used: bool,
    #[serde(default)]
    pub license: Option<Record>,
    /// Activations this Mac gave up but could not yet deactivate; retried until Dodo answers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stale: Vec<Probe>,
}

/// The product IDs this app accepts for the current Dodo environment.
#[derive(Clone, Debug, PartialEq)]
pub struct Products {
    pub paid: Vec<String>,
    pub trial: Vec<String>,
}

impl Products {
    fn classify(&self, product_id: &str) -> Option<Kind> {
        if self.paid.iter().any(|id| id == product_id) {
            Some(Kind::Paid)
        } else if self.trial.iter().any(|id| id == product_id) {
            Some(Kind::Trial)
        } else {
            None
        }
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
    /// `5xx`, timeout or no network: grace rules apply and state never gets worse.
    Offline(String),
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "state",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum State {
    Unlicensed,
    Trial { days_left: u32 },
    TrialEnded,
    Licensed,
    Grace { days_offline: u32, days_left: u32 },
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

/// What the user was doing when they entered a key. Lets the app refuse a second trial locally.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyHint {
    Any,
    Trial,
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
    TrialUsed,
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
            LicenseError::TrialUsed => "The trial was already used on this Mac.".into(),
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
            DodoError::Offline(_) | DodoError::Unexpected(_) => LicenseError::Unreachable,
        }
    }
}

/// When the next check may run. Rate limits are hard holds; backoff after failures is soft and a
/// user's "Try again" skips it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Schedule {
    pub failures: u32,
    pub retry_at: Option<i64>,
    pub hold_until: Option<i64>,
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

    /// Dodo could not be reached: retry with backoff.
    fn failed(&mut self, now: i64) {
        self.failures += 1;
        self.retry_at = Some(now + Self::backoff(self.failures));
    }

    /// `429`: no call of any kind until `Retry-After` has passed. Not a failure, so the state
    /// does not change.
    fn hold(&mut self, now: i64, retry_after: i64) {
        self.hold_until = Some(now + retry_after.clamp(1, MAX_HOLD));
    }

    fn succeeded(&mut self) {
        *self = Self::default();
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
    pub products: Products,
    pub schedule: Schedule,
}

impl Engine {
    pub fn new(stored: Stored, products: Products) -> Self {
        Self {
            stored,
            products,
            schedule: Schedule::default(),
        }
    }

    /// The clock the trial is measured against: never earlier than any moment already seen, so
    /// rolling the clock back cannot add days.
    fn trial_clock(record: &Record, now: i64) -> i64 {
        now.max(record.seen_at)
    }

    pub fn state(&self, now: i64) -> State {
        let Some(record) = &self.stored.license else {
            return State::Unlicensed;
        };
        match record.kind {
            Kind::Trial => {
                let now = Self::trial_clock(record, now);
                let expires_at = record.activated_at + TRIAL_LENGTH;
                if record.revoked || now >= expires_at {
                    State::TrialEnded
                } else {
                    State::Trial {
                        days_left: days_up(expires_at - now).min(days_up(TRIAL_LENGTH)),
                    }
                }
            }
            Kind::Paid => {
                if record.revoked {
                    return State::Revoked;
                }
                let age = now - record.last_success_at;
                if !(-CLOCK_ROLLBACK_TOLERANCE..=GRACE_PERIOD).contains(&age) {
                    State::CheckRequired
                } else if age > CHECK_INTERVAL && self.schedule.failures > 0 {
                    State::Grace {
                        days_offline: (age / DAY) as u32,
                        days_left: days_up(GRACE_PERIOD - age),
                    }
                } else {
                    State::Licensed
                }
            }
        }
    }

    pub fn core_feature(&self, now: i64) -> bool {
        self.state(now).core_feature()
    }

    /// Notes that `now` has been reached. Returns whether the record changed and should be saved.
    pub fn observe(&mut self, now: i64) -> bool {
        match self.stored.license.as_mut() {
            Some(record) if now > record.seen_at => {
                record.seen_at = now;
                true
            }
            _ => false,
        }
    }

    /// The record that daily checks apply to: an activation that is not already ended or revoked.
    fn checkable(&self, now: i64) -> Option<&Record> {
        self.stored
            .license
            .as_ref()
            .filter(|record| !record.revoked)
            .filter(|record| {
                record.kind == Kind::Paid
                    || Self::trial_clock(record, now) < record.activated_at + TRIAL_LENGTH
            })
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
    pub fn next_check_at(&self, now: i64) -> Option<i64> {
        let record = self.checkable(now)?;
        // After a failure the backoff decides; otherwise the daily schedule does.
        let mut due = match self.schedule.retry_at {
            Some(retry_at) => retry_at,
            None if now < record.last_success_at - CLOCK_ROLLBACK_TOLERANCE => now,
            None => record.last_success_at + CHECK_INTERVAL,
        };
        if let Some(hold_until) = self.schedule.hold_until {
            due = due.max(hold_until);
        }
        Some(due)
    }

    pub fn check_due(&self, now: i64) -> bool {
        self.next_check_at(now).is_some_and(|due| due <= now)
    }

    /// The next moment the state changes by time alone: a trial's estimated expiry, the grace
    /// warning, or the end of grace. Independent of any network schedule.
    pub fn next_transition_at(&self, now: i64) -> Option<i64> {
        let record = self.checkable(now)?;
        let candidates = match record.kind {
            Kind::Trial => {
                vec![record.activated_at + TRIAL_LENGTH - (Self::trial_clock(record, now) - now)]
            }
            Kind::Paid => vec![
                record.last_success_at + GRACE_WARNING_AFTER,
                record.last_success_at + GRACE_PERIOD,
            ],
        };
        candidates.into_iter().filter(|at| *at > now).min()
    }

    /// Whether an activation call may be made now. Refuses a second trial locally.
    pub fn activation_allowed(
        &self,
        key: &str,
        hint: KeyHint,
        now: i64,
    ) -> Result<(), LicenseError> {
        if key.trim().is_empty() {
            return Err(LicenseError::EmptyKey);
        }
        if hint == KeyHint::Trial && self.stored.trial_used {
            return Err(LicenseError::TrialUsed);
        }
        self.held(now)
    }

    /// `429`: nothing is called again until `Retry-After` has passed.
    pub fn note_rate_limit(&mut self, now: i64, retry_after: i64) {
        self.schedule.hold(now, retry_after);
    }

    /// Applies the product check to a fresh activation. Nothing is stored yet: the caller
    /// persists `Activated::next` before `commit_activation`, and gives a refused or unsaved
    /// activation's slot back with `apply_release`.
    pub fn accept_activation(
        &self,
        key: &str,
        activation: Activation,
        now: i64,
    ) -> Result<Activated, Refusal> {
        let probe = Probe {
            license_key: key.trim().to_string(),
            instance_id: activation.id,
        };
        let kind = match self.products.classify(&activation.product_id) {
            // Another app's key or the wrong environment.
            None => {
                return Err(Refusal {
                    probe,
                    error: LicenseError::WrongProduct {
                        product_name: activation.product_name,
                    },
                });
            }
            Some(Kind::Trial) if self.stored.trial_used => {
                return Err(Refusal {
                    probe,
                    error: LicenseError::TrialUsed,
                });
            }
            Some(kind) => kind,
        };
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
            kind,
            activated_at: activation.created_at,
            last_success_at: activation.server_time.unwrap_or(now),
            seen_at: now,
            revoked: false,
        });
        next.trial_used |= kind == Kind::Trial;
        Ok(Activated {
            next,
            replaced,
            probe,
        })
    }

    /// Puts a saved activation into effect. Returns the activation it replaced (for example the
    /// trial), whose slot the caller frees with `apply_release`.
    pub fn commit_activation(&mut self, activated: Activated) -> Option<Probe> {
        self.stored = activated.next;
        self.schedule.succeeded();
        activated.replaced
    }

    /// Records the outcome of deactivating an activation this Mac no longer uses. A failure is
    /// remembered in `Stored::stale` and retried through `take_stale`, so a slot is never lost.
    pub fn apply_release(&mut self, probe: Probe, answer: Result<(), DodoError>, now: i64) {
        match answer {
            Ok(()) | Err(DodoError::KeyNotFound) | Err(DodoError::KeyDisabled) => {}
            Err(error) => {
                if let DodoError::RateLimited { retry_after } = error {
                    self.schedule.hold(now, retry_after);
                }
                self.remember_stale(probe);
            }
        }
    }

    pub fn remember_stale(&mut self, probe: Probe) {
        if !self.stored.stale.contains(&probe) {
            self.stored.stale.push(probe);
        }
    }

    /// Deactivations to retry now; empty while a rate limit holds. Each answer goes back through
    /// `apply_release`.
    pub fn take_stale(&mut self, now: i64) -> Vec<Probe> {
        if self.held(now).is_err() {
            return Vec::new();
        }
        std::mem::take(&mut self.stored.stale)
    }

    /// Starts a validation. `Ok(None)` when there is nothing to check, or the check is not due and
    /// not forced. The answer goes to `finish_check`, which ignores it if the record changed.
    pub fn begin_check(&self, now: i64, forced: bool) -> Result<Option<Probe>, LicenseError> {
        let Some(record) = self.checkable(now) else {
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
        now: i64,
    ) -> Result<State, LicenseError> {
        let current = self
            .stored
            .license
            .as_mut()
            .filter(|record| record.instance_id == probe.instance_id);
        let Some(record) = current else {
            return Ok(self.state(now));
        };
        match answer {
            Ok(validation) => {
                if validation.valid {
                    record.last_success_at = validation.server_time.unwrap_or(now);
                } else {
                    record.revoked = true;
                }
                self.schedule.succeeded();
                Ok(self.state(now))
            }
            Err(DodoError::RateLimited { retry_after }) => {
                self.schedule.hold(now, retry_after);
                Err(LicenseError::RateLimited { retry_after })
            }
            Err(_) => {
                self.schedule.failed(now);
                Err(LicenseError::Unreachable)
            }
        }
    }

    /// Settings → License → Remove this Mac: the activation to deactivate, or why not now.
    pub fn begin_remove(&self, now: i64) -> Result<Probe, LicenseError> {
        let Some(record) = &self.stored.license else {
            return Err(LicenseError::NothingToRemove);
        };
        if self.held(now).is_err() {
            return Err(LicenseError::RemoveOffline);
        }
        Ok(Probe {
            license_key: record.license_key.clone(),
            instance_id: record.instance_id.clone(),
        })
    }

    /// Clears the record once Dodo has deactivated it (or no longer knows it). If the record
    /// changed meanwhile the answer is ignored.
    pub fn finish_remove(
        &mut self,
        probe: &Probe,
        answer: Result<(), DodoError>,
        now: i64,
    ) -> Result<State, LicenseError> {
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
                    self.schedule.succeeded();
                }
                Ok(self.state(now))
            }
            Err(DodoError::RateLimited { retry_after }) => {
                self.schedule.hold(now, retry_after);
                Err(LicenseError::RemoveOffline)
            }
            Err(_) => Err(LicenseError::RemoveOffline),
        }
    }
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
    pub fn activate(
        &mut self,
        key: &str,
        hint: KeyHint,
        dodo: &dyn Dodo,
        now: i64,
    ) -> Result<Activated, LicenseError> {
        self.activation_allowed(key, hint, now)?;
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
        if let Some(replaced) = self.commit_activation(activated) {
            self.release(replaced, dodo, now);
        }
        self.state(now)
    }

    pub fn abandon_activation(&mut self, activated: Activated, dodo: &dyn Dodo, now: i64) {
        self.release(activated.probe, dodo, now);
    }

    fn release(&mut self, probe: Probe, dodo: &dyn Dodo, now: i64) {
        if self.held(now).is_err() {
            self.remember_stale(probe);
            return;
        }
        let answer = dodo.deactivate(&probe.license_key, &probe.instance_id);
        self.apply_release(probe, answer, now);
    }

    pub fn release_stale(&mut self, dodo: &dyn Dodo, now: i64) -> bool {
        let pending = self.take_stale(now);
        let before = pending.len();
        for probe in pending {
            self.release(probe, dodo, now);
        }
        before > 0 && self.stored.stale.len() != before
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
}

fn days_up(seconds: i64) -> u32 {
    ((seconds.max(0) + DAY - 1) / DAY) as u32
}

#[cfg(test)]
pub(crate) mod tests {
    //! The shared test cases from LICENSING.md, numbered as in the document.
    use super::*;
    use std::cell::RefCell;

    const P: &str = "pdt_openklack";
    const T: &str = "pdt_openklack_trial";
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
                T => "OpenKlack Trial",
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

    /// The runtime's happy path: activate, save, commit.
    fn activate(
        engine: &mut Engine,
        key: &str,
        hint: KeyHint,
        dodo: &dyn Dodo,
        now: i64,
    ) -> Result<State, LicenseError> {
        let activated = engine.activate(key, hint, dodo, now)?;
        Ok(engine.commit(activated, dodo, now))
    }

    fn products() -> Products {
        Products {
            paid: vec![P.into()],
            trial: vec![T.into()],
        }
    }

    fn unlicensed() -> Engine {
        Engine::new(Stored::default(), products())
    }

    fn licensed(last_success_ago: i64) -> Engine {
        Engine::new(
            Stored {
                trial_used: false,
                license: Some(Record {
                    license_key: "KEY-PAID".into(),
                    instance_id: "lki_paid".into(),
                    product_id: P.into(),
                    kind: Kind::Paid,
                    activated_at: NOW - 30 * DAY,
                    last_success_at: NOW - last_success_ago,
                    seen_at: NOW - last_success_ago,
                    revoked: false,
                }),
                stale: vec![],
            },
            products(),
        )
    }

    fn trial(activated_ago: i64) -> Engine {
        Engine::new(
            Stored {
                trial_used: true,
                license: Some(Record {
                    license_key: "KEY-TRIAL".into(),
                    instance_id: "lki_trial".into(),
                    product_id: T.into(),
                    kind: Kind::Trial,
                    activated_at: NOW - activated_ago,
                    last_success_at: NOW - activated_ago,
                    seen_at: NOW - activated_ago,
                    revoked: false,
                }),
                stale: vec![],
            },
            products(),
        )
    }

    #[test]
    fn case_01_paid_key_activates_and_saves_a_paid_record() {
        let mut engine = unlicensed();
        let dodo = Fake::activating(P);
        assert_eq!(
            activate(&mut engine, " KEY-PAID ", KeyHint::Any, &dodo, NOW),
            Ok(State::Licensed)
        );
        let record = engine.stored.license.as_ref().unwrap();
        assert_eq!(record.kind, Kind::Paid);
        assert_eq!(record.license_key, "KEY-PAID");
        assert_eq!(record.instance_id, "lki_pdt_openklack");
        assert_eq!(record.activated_at, NOW);
        assert_eq!(record.last_success_at, NOW);
        assert!(!engine.stored.trial_used);
        assert!(engine.core_feature(NOW));
        assert_eq!(
            dodo.calls(),
            vec![Call::Activate("KEY-PAID".into(), "Mac".into())]
        );
    }

    #[test]
    fn case_02_another_apps_key_is_deactivated_and_nothing_is_saved() {
        let mut engine = unlicensed();
        let dodo = Fake::activating(X);
        let error = activate(&mut engine, "KEY-X", KeyHint::Any, &dodo, NOW).unwrap_err();
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
        assert_eq!(engine.state(NOW), State::Unlicensed);
    }

    #[test]
    fn case_03_all_macs_activated_leaves_the_mac_unlicensed() {
        let mut engine = unlicensed();
        let dodo = Fake::failing(DodoError::LimitReached);
        let error = activate(&mut engine, "KEY-PAID", KeyHint::Any, &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::LimitReached);
        assert!(error.message().starts_with("All 3 Macs"));
        assert_eq!(engine.state(NOW), State::Unlicensed);
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
            let mut engine = unlicensed();
            let dodo = Fake::failing(error);
            let result = activate(&mut engine, "KEY", KeyHint::Any, &dodo, NOW);
            assert_eq!(result, Err(expected));
            assert_eq!(result.unwrap_err().message(), message);
            assert_eq!(engine.state(NOW), State::Unlicensed);
            assert_eq!(engine.stored, Stored::default());
        }
    }

    #[test]
    fn case_05_a_timeout_during_activation_saves_nothing() {
        let mut engine = unlicensed();
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        let error = activate(&mut engine, "KEY-PAID", KeyHint::Any, &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::Unreachable);
        assert_eq!(
            error.message(),
            "OpenKlack couldn't reach the license service. Check your connection and try again."
        );
        assert_eq!(engine.state(NOW), State::Unlicensed);
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
        assert_eq!(engine.schedule.retry_at, Some(NOW + MIN_BACKOFF));
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
        assert_eq!(engine.next_check_at(NOW), None);
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
    fn case_12_a_trial_key_starts_the_trial_and_marks_it_used() {
        let mut engine = unlicensed();
        let dodo = Fake::activating(T);
        assert_eq!(
            activate(&mut engine, "KEY-TRIAL", KeyHint::Trial, &dodo, NOW),
            Ok(State::Trial { days_left: 3 })
        );
        assert!(engine.stored.trial_used);
        assert_eq!(engine.stored.license.as_ref().unwrap().kind, Kind::Trial);
        assert!(engine.core_feature(NOW));
        assert_eq!(
            engine.state(NOW + DAY + HOUR),
            State::Trial { days_left: 2 }
        );
    }

    #[test]
    fn case_13_an_expired_trial_ends_on_launch_without_a_network() {
        let engine = trial(3 * DAY + 60);
        assert_eq!(engine.state(NOW), State::TrialEnded);
        assert!(!engine.core_feature(NOW));
        assert_eq!(engine.next_check_at(NOW), None, "nothing left to check");
        assert!(engine.stored.trial_used);
    }

    #[test]
    fn case_14_valid_false_ends_a_running_trial() {
        let mut engine = trial(DAY);
        assert_eq!(engine.state(NOW), State::Trial { days_left: 2 });
        let dodo = Fake::validating(false);
        assert_eq!(engine.check(&dodo, NOW), Ok(State::TrialEnded));
        assert!(!engine.core_feature(NOW));
    }

    #[test]
    fn case_15_a_second_trial_is_refused_without_calling_dodo() {
        let mut engine = Engine::new(
            Stored {
                trial_used: true,
                ..Stored::default()
            },
            products(),
        );
        let dodo = Fake::activating(T);
        let error = activate(&mut engine, "KEY-TRIAL-2", KeyHint::Trial, &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::TrialUsed);
        assert_eq!(error.message(), "The trial was already used on this Mac.");
        assert!(dodo.calls().is_empty(), "Dodo is not called");
        assert_eq!(engine.state(NOW), State::Unlicensed);
        // A trial key pasted without saying so still cannot start a second trial: the slot is
        // given back and nothing is stored.
        let error = activate(&mut engine, "KEY-TRIAL-2", KeyHint::Any, &dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::TrialUsed);
        assert_eq!(
            dodo.calls(),
            vec![
                Call::Activate("KEY-TRIAL-2".into(), "Mac".into()),
                Call::Deactivate("KEY-TRIAL-2".into(), "lki_pdt_openklack_trial".into())
            ]
        );
        assert!(engine.stored.license.is_none());
    }

    #[test]
    fn case_16_buying_during_a_trial_licenses_the_mac_and_frees_the_trial_slot() {
        let mut engine = trial(DAY);
        let dodo = Fake::activating(P);
        assert_eq!(
            activate(&mut engine, "KEY-PAID", KeyHint::Any, &dodo, NOW),
            Ok(State::Licensed)
        );
        let record = engine.stored.license.as_ref().unwrap();
        assert_eq!(record.kind, Kind::Paid);
        assert_eq!(record.license_key, "KEY-PAID");
        assert!(engine.stored.trial_used, "the trial stays used");
        assert_eq!(
            dodo.calls(),
            vec![
                Call::Activate("KEY-PAID".into(), "Mac".into()),
                Call::Deactivate("KEY-TRIAL".into(), "lki_trial".into())
            ]
        );
    }

    #[test]
    fn case_17_removing_this_mac_clears_everything_but_trial_used() {
        let mut engine = licensed(HOUR);
        engine.stored.trial_used = true;
        let dodo = Fake::default();
        assert_eq!(engine.remove(&dodo, NOW), Ok(State::Unlicensed));
        assert_eq!(
            engine.stored,
            Stored {
                trial_used: true,
                ..Stored::default()
            }
        );
        assert_eq!(
            dodo.calls(),
            vec![Call::Deactivate("KEY-PAID".into(), "lki_paid".into())]
        );
        assert!(!engine.core_feature(NOW));
    }

    #[test]
    fn case_18_removing_this_mac_offline_keeps_the_license_and_asks_to_retry() {
        let mut engine = licensed(HOUR);
        let dodo = Fake::failing(DodoError::Offline("timed out".into()));
        let error = engine.remove(&dodo, NOW).unwrap_err();
        assert_eq!(error, LicenseError::RemoveOffline);
        assert!(error.message().contains("try again"));
        assert_eq!(engine.state(NOW), State::Licensed);
        assert!(engine.stored.license.is_some());
    }

    #[test]
    fn case_19_a_rate_limit_holds_every_call_for_retry_after_and_changes_nothing() {
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
        // Unlicensed: activation is held the same way.
        let mut engine = unlicensed();
        let dodo = Fake::failing(rate_limited);
        assert_eq!(
            activate(&mut engine, "KEY", KeyHint::Any, &dodo, NOW),
            Err(LicenseError::RateLimited { retry_after: 60 })
        );
        assert_eq!(
            activate(&mut engine, "KEY", KeyHint::Any, &dodo, NOW + 10),
            Err(LicenseError::RateLimited { retry_after: 50 })
        );
        assert_eq!(dodo.calls().len(), 1);
        assert_eq!(engine.stored, Stored::default());
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
        let mut engine = trial(DAY);
        let trial_probe = engine.begin_check(NOW, true).unwrap().unwrap();
        assert_eq!(trial_probe.instance_id, "lki_trial");
        // The user buys while the trial's check is in flight.
        assert_eq!(
            activate(
                &mut engine,
                "KEY-PAID",
                KeyHint::Any,
                &Fake::activating(P),
                NOW
            ),
            Ok(State::Licensed)
        );
        let late_false = Ok(Validation {
            valid: false,
            server_time: Some(NOW + 10),
        });
        assert_eq!(
            engine.finish_check(&trial_probe, late_false, NOW + 10),
            Ok(State::Licensed)
        );
        let record = engine.stored.license.as_ref().unwrap();
        assert!(
            !record.revoked,
            "a late `false` for the trial must not revoke the paid key"
        );
        assert_eq!(record.last_success_at, NOW);
        let late_true = Ok(Validation {
            valid: true,
            server_time: Some(NOW + 20),
        });
        engine
            .finish_check(&trial_probe, late_true, NOW + 20)
            .unwrap();
        assert_eq!(engine.stored.license.as_ref().unwrap().last_success_at, NOW);
        // A late failure for the old activation must not touch the retry schedule either.
        engine
            .finish_check(
                &trial_probe,
                Err(DodoError::Offline("late".into())),
                NOW + 30,
            )
            .unwrap();
        assert_eq!(engine.schedule, Schedule::default());
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
        assert_eq!(restarted.next_check_at(NOW + DAY), None);
        assert_eq!(restarted.begin_check(NOW + DAY, true), Ok(None));
        // Only a new activation clears it, and the new record starts clean.
        let mut restarted = restarted;
        assert_eq!(
            activate(
                &mut restarted,
                "KEY-PAID-2",
                KeyHint::Any,
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
        // Trial: expiry arrives regardless of backoff.
        let mut engine = trial(TRIAL_LENGTH - 60);
        assert!(
            engine
                .check(&Fake::failing(DodoError::Offline("down".into())), NOW)
                .is_err()
        );
        assert_eq!(engine.next_transition_at(NOW), Some(NOW + 60));
        assert_eq!(engine.state(NOW + 60), State::TrialEnded);
        assert_eq!(engine.next_transition_at(NOW + 60), None);
    }

    #[test]
    fn trial_days_never_exceed_three_and_a_rolled_back_clock_adds_none() {
        let mut engine = trial(DAY);
        assert!(engine.observe(NOW));
        assert!(!engine.observe(NOW - 1), "earlier times are not recorded");
        // Rolling the clock back two days still leaves about two days.
        assert_eq!(engine.state(NOW - 2 * DAY), State::Trial { days_left: 2 });
        assert_eq!(engine.next_transition_at(NOW - 2 * DAY), Some(NOW));
        // A record with a bad `activated_at` in the future is clamped to the trial length.
        let mut future = trial(0);
        future.stored.license.as_mut().unwrap().activated_at = NOW + 10 * DAY;
        assert_eq!(future.state(NOW), State::Trial { days_left: 3 });
        // Once the high-water mark has passed the expiry, no clock setting brings it back.
        assert!(engine.observe(NOW + TRIAL_LENGTH));
        assert_eq!(engine.state(NOW - 10 * DAY), State::TrialEnded);
        assert_eq!(engine.next_check_at(NOW - 10 * DAY), None);
        let json = serde_json::to_string(&engine.stored).unwrap();
        let restarted = Engine::new(serde_json::from_str(&json).unwrap(), products());
        assert_eq!(restarted.state(NOW), State::TrialEnded);
    }

    #[test]
    fn an_activation_that_cannot_be_saved_is_abandoned_and_the_old_one_kept() {
        let mut engine = trial(DAY);
        let before = engine.stored.clone();
        let dodo = Fake::activating(P);
        let activated = engine
            .activate("KEY-PAID", KeyHint::Any, &dodo, NOW)
            .unwrap();
        assert_eq!(
            engine.stored, before,
            "nothing changes before the record is saved"
        );
        assert_eq!(activated.next.license.as_ref().unwrap().kind, Kind::Paid);
        assert_eq!(
            activated.replaced,
            Some(Probe {
                license_key: "KEY-TRIAL".into(),
                instance_id: "lki_trial".into()
            })
        );
        assert_eq!(dodo.calls().len(), 1, "the trial is not deactivated yet");
        // Saving failed: give the new slot back, keep the trial.
        engine.abandon_activation(activated, &dodo, NOW);
        assert_eq!(engine.stored, before);
        assert_eq!(engine.state(NOW), State::Trial { days_left: 2 });
        assert_eq!(
            dodo.calls()[1],
            Call::Deactivate("KEY-PAID".into(), "lki_pdt_openklack".into())
        );
        // If even that fails, the slot is remembered and freed later.
        let activated = engine
            .activate("KEY-PAID", KeyHint::Any, &dodo, NOW)
            .unwrap();
        let down = Fake::failing(DodoError::Offline("down".into()));
        engine.abandon_activation(activated, &down, NOW);
        assert_eq!(engine.stored.license, before.license);
        assert_eq!(engine.stored.stale.len(), 1);
        assert!(engine.release_stale(&Fake::default(), NOW + 60));
        assert!(engine.stored.stale.is_empty());
    }

    #[test]
    fn replacing_a_paid_activation_frees_the_old_slot_or_remembers_it() {
        let mut engine = licensed(HOUR);
        let dodo = Fake::activating(P);
        dodo.deactivate
            .borrow_mut()
            .push(Err(DodoError::Offline("down".into())));
        assert_eq!(
            activate(&mut engine, "KEY-PAID-2", KeyHint::Any, &dodo, NOW),
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
            engine.stored.stale,
            vec![Probe {
                license_key: "KEY-PAID".into(),
                instance_id: "lki_paid".into()
            }]
        );
        // Still offline: nothing is dropped. Back online: freed and forgotten.
        assert!(!engine.release_stale(&Fake::failing(DodoError::Offline("down".into())), NOW + 60));
        assert_eq!(engine.stored.stale.len(), 1);
        let later = Fake::default();
        assert!(engine.release_stale(&later, NOW + 120));
        assert!(engine.stored.stale.is_empty());
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
        assert!(engine.activate("KEY-X", KeyHint::Any, &dodo, NOW).is_err());
        assert!(engine.stored.license.is_none());
        assert_eq!(engine.stored.stale[0].instance_id, "lki_pdt_openreaction");
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
        assert!(!engine.release_stale(&dodo, NOW + 70));
        assert_eq!(engine.remove(&dodo, NOW + 121), Ok(State::Unlicensed));
    }

    #[test]
    fn freeing_slots_honours_rate_limits_and_holds_are_bounded_to_a_day() {
        let mut engine = licensed(HOUR);
        let limited = Fake::failing(DodoError::RateLimited { retry_after: 120 });
        let activated = engine
            .activate("KEY-PAID-2", KeyHint::Any, &Fake::activating(P), NOW)
            .unwrap();
        // The old slot's deactivation is rate limited: remembered, and nothing else is called
        // until the hold passes, including a refused key's slot.
        assert_eq!(engine.commit(activated, &limited, NOW), State::Licensed);
        assert_eq!(engine.stored.stale.len(), 1);
        assert_eq!(engine.schedule.hold_until, Some(NOW + 120));
        let refused = Fake::activating(X);
        assert!(
            engine
                .activate("KEY-X", KeyHint::Any, &refused, NOW + 10)
                .is_err()
        );
        assert!(
            refused.calls().is_empty(),
            "held: not even the activation call"
        );
        assert!(!engine.release_stale(&refused, NOW + 10));
        assert!(refused.calls().is_empty());
        assert_eq!(engine.stored.stale.len(), 1);
        assert!(engine.release_stale(&Fake::default(), NOW + 120));
        assert!(engine.stored.stale.is_empty());
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
            activate(
                &mut engine,
                "KEY-PAID-2",
                KeyHint::Any,
                &Fake::activating(P),
                NOW
            ),
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
        // Back on the daily schedule, counted from the server's time of the success.
        assert_eq!(engine.next_check_at(NOW + MIN_BACKOFF), Some(NOW + DAY));
    }

    #[test]
    fn the_stored_record_round_trips_and_tolerates_older_shapes() {
        let stored = Stored {
            trial_used: true,
            license: Some(Record {
                license_key: "KEY".into(),
                instance_id: "lki".into(),
                product_id: P.into(),
                kind: Kind::Paid,
                activated_at: NOW,
                last_success_at: NOW,
                seen_at: NOW,
                revoked: false,
            }),
            stale: vec![],
        };
        let json = serde_json::to_string(&stored).unwrap();
        assert_eq!(serde_json::from_str::<Stored>(&json).unwrap(), stored);
        assert_eq!(
            serde_json::from_str::<Stored>("{}").unwrap(),
            Stored::default()
        );
    }
}
