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
    /// Set by `valid: false`; only a new paid activation clears it.
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
    RateLimited { retry_after: i64 },
    WrongProduct { product_name: String },
    TrialUsed,
    NothingToRemove,
    RemoveOffline,
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
        self.hold_until = Some(now + retry_after.max(1));
    }

    fn succeeded(&mut self) {
        *self = Self::default();
    }
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

    pub fn state(&self, now: i64) -> State {
        let Some(record) = &self.stored.license else {
            return State::Unlicensed;
        };
        match record.kind {
            Kind::Trial => {
                let expires_at = record.activated_at + TRIAL_LENGTH;
                if record.revoked || now >= expires_at {
                    State::TrialEnded
                } else {
                    State::Trial {
                        days_left: days_up(expires_at - now),
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

    /// The record that daily checks apply to: an activation that is not already ended or revoked.
    fn checkable(&self, now: i64) -> Option<&Record> {
        self.stored
            .license
            .as_ref()
            .filter(|record| !record.revoked)
            .filter(|record| record.kind == Kind::Paid || now < record.activated_at + TRIAL_LENGTH)
    }

    /// When the scheduler should run the next check, or `None` while there is nothing to check.
    pub fn next_check_at(&self, now: i64) -> Option<i64> {
        let record = self.checkable(now)?;
        let mut due = record.last_success_at + CHECK_INTERVAL;
        if now < record.last_success_at - CLOCK_ROLLBACK_TOLERANCE {
            due = now;
        }
        if let Some(retry_at) = self.schedule.retry_at {
            due = due.max(retry_at);
        }
        if let Some(hold_until) = self.schedule.hold_until {
            due = due.max(hold_until);
        }
        Some(due)
    }

    pub fn check_due(&self, now: i64) -> bool {
        self.next_check_at(now).is_some_and(|due| due <= now)
    }

    /// The next moment the state changes by time alone: a trial's estimated expiry, the grace
    /// warning, or the end of grace.
    pub fn next_transition_at(&self, now: i64) -> Option<i64> {
        let record = self.checkable(now)?;
        let candidates = match record.kind {
            Kind::Trial => vec![record.activated_at + TRIAL_LENGTH],
            Kind::Paid => vec![
                record.last_success_at + GRACE_WARNING_AFTER,
                record.last_success_at + GRACE_PERIOD,
            ],
        };
        candidates.into_iter().filter(|at| *at > now).min()
    }

    /// Activate a key, apply the product check, and store the record on success.
    pub fn activate(
        &mut self,
        key: &str,
        hint: KeyHint,
        dodo: &dyn Dodo,
        now: i64,
    ) -> Result<State, LicenseError> {
        let key = key.trim();
        if key.is_empty() {
            return Err(LicenseError::EmptyKey);
        }
        if hint == KeyHint::Trial && self.stored.trial_used {
            return Err(LicenseError::TrialUsed);
        }
        if let Some(hold_until) = self.schedule.hold_until
            && now < hold_until
        {
            return Err(LicenseError::RateLimited {
                retry_after: hold_until - now,
            });
        }
        let activation = match dodo.activate(key, ACTIVATION_NAME) {
            Ok(activation) => activation,
            Err(DodoError::RateLimited { retry_after }) => {
                self.schedule.hold(now, retry_after);
                return Err(LicenseError::RateLimited { retry_after });
            }
            Err(error) => return Err(error.into()),
        };
        let kind = match self.products.classify(&activation.product_id) {
            Some(kind) => kind,
            None => {
                // Another app's key or the wrong environment: give the slot back and keep nothing.
                let _ = dodo.deactivate(key, &activation.id);
                return Err(LicenseError::WrongProduct {
                    product_name: activation.product_name,
                });
            }
        };
        if kind == Kind::Trial && self.stored.trial_used {
            let _ = dodo.deactivate(key, &activation.id);
            return Err(LicenseError::TrialUsed);
        }
        if let Some(previous) = self.stored.license.take()
            && previous.instance_id != activation.id
        {
            // Best effort: free the slot of the activation this one replaces (for example the trial).
            let _ = dodo.deactivate(&previous.license_key, &previous.instance_id);
        }
        self.stored.license = Some(Record {
            license_key: key.to_string(),
            instance_id: activation.id,
            product_id: activation.product_id,
            kind,
            activated_at: activation.created_at,
            last_success_at: activation.server_time.unwrap_or(now),
            revoked: false,
        });
        if kind == Kind::Trial {
            self.stored.trial_used = true;
        }
        self.schedule.succeeded();
        Ok(self.state(now))
    }

    /// Run one validation. `Err` means Dodo did not answer; the state is unchanged apart from the
    /// retry schedule and can be read with `state`.
    pub fn check(&mut self, dodo: &dyn Dodo, now: i64) -> Result<State, LicenseError> {
        let Some(record) = self.checkable(now) else {
            return Ok(self.state(now));
        };
        if let Some(hold_until) = self.schedule.hold_until
            && now < hold_until
        {
            return Err(LicenseError::RateLimited {
                retry_after: hold_until - now,
            });
        }
        match dodo.validate(&record.license_key, &record.instance_id) {
            Ok(validation) => {
                let record = self.stored.license.as_mut().expect("checkable record");
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

    /// Settings → License → Remove this Mac.
    pub fn remove(&mut self, dodo: &dyn Dodo, now: i64) -> Result<State, LicenseError> {
        let Some(record) = &self.stored.license else {
            return Err(LicenseError::NothingToRemove);
        };
        match dodo.deactivate(&record.license_key, &record.instance_id) {
            // Already gone on Dodo's side: the slot is free, so forget it here too.
            Ok(()) | Err(DodoError::KeyNotFound) | Err(DodoError::KeyDisabled) => {
                self.stored.license = None;
                self.schedule.succeeded();
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
                    revoked: false,
                }),
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
                    revoked: false,
                }),
            },
            products(),
        )
    }

    #[test]
    fn case_01_paid_key_activates_and_saves_a_paid_record() {
        let mut engine = unlicensed();
        let dodo = Fake::activating(P);
        assert_eq!(
            engine.activate(" KEY-PAID ", KeyHint::Any, &dodo, NOW),
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
        let error = engine
            .activate("KEY-X", KeyHint::Any, &dodo, NOW)
            .unwrap_err();
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
        let error = engine
            .activate("KEY-PAID", KeyHint::Any, &dodo, NOW)
            .unwrap_err();
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
            let result = engine.activate("KEY", KeyHint::Any, &dodo, NOW);
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
        let error = engine
            .activate("KEY-PAID", KeyHint::Any, &dodo, NOW)
            .unwrap_err();
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
            engine.activate("KEY-TRIAL", KeyHint::Trial, &dodo, NOW),
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
                license: None,
            },
            products(),
        );
        let dodo = Fake::activating(T);
        let error = engine
            .activate("KEY-TRIAL-2", KeyHint::Trial, &dodo, NOW)
            .unwrap_err();
        assert_eq!(error, LicenseError::TrialUsed);
        assert_eq!(error.message(), "The trial was already used on this Mac.");
        assert!(dodo.calls().is_empty(), "Dodo is not called");
        assert_eq!(engine.state(NOW), State::Unlicensed);
        // A trial key pasted without saying so still cannot start a second trial: the slot is
        // given back and nothing is stored.
        let error = engine
            .activate("KEY-TRIAL-2", KeyHint::Any, &dodo, NOW)
            .unwrap_err();
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
            engine.activate("KEY-PAID", KeyHint::Any, &dodo, NOW),
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
                license: None
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
            engine.activate("KEY", KeyHint::Any, &dodo, NOW),
            Err(LicenseError::RateLimited { retry_after: 60 })
        );
        assert_eq!(
            engine.activate("KEY", KeyHint::Any, &dodo, NOW + 10),
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
                revoked: false,
            }),
        };
        let json = serde_json::to_string(&stored).unwrap();
        assert_eq!(serde_json::from_str::<Stored>(&json).unwrap(), stored);
        assert_eq!(
            serde_json::from_str::<Stored>("{}").unwrap(),
            Stored::default()
        );
    }
}
