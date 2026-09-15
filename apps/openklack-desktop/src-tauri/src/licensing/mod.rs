//! Licensing for official builds, following LICENSING.md at the repository root.
//!
//! The `licensing` cargo feature is off by default: a build from source has no License UI,
//! never contacts the license service, and plays sounds without restriction.

pub const ENABLED: bool = cfg!(feature = "licensing");

#[cfg(any(feature = "licensing", test))]
#[cfg_attr(not(feature = "licensing"), allow(dead_code))]
pub mod core;
#[cfg(feature = "licensing")]
pub mod runtime;
#[cfg(feature = "licensing")]
pub mod store;

#[cfg(all(test, not(feature = "licensing")))]
mod source_build {
    use crate::model::{Preferences, Runtime};

    /// Shared case 26: a source build launches with no License UI, no trial, no registry or
    /// license calls (the runtime is not compiled in), and sounds on.
    #[test]
    #[allow(clippy::assertions_on_constants)]
    fn case_26_a_source_build_has_no_licensing_and_sounds_stay_on() {
        assert!(!super::ENABLED, "the settings UI hides the License section");
        let runtime = Runtime {
            input_permission: true,
            audio_ready: true,
            ..Runtime::default()
        };
        assert!(!runtime.license_blocked);
        assert_eq!(runtime.pause_reason(&Preferences::default()), None);
    }
}
