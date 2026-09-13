use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Duration;

// Aggregate counters only. Never retain a key identity, event history, app name, or file path.
#[derive(Default)]
pub struct Metrics {
    pub presses: AtomicU64,
    pub releases: AtomicU64,
    pub paused_events: AtomicU64,
    pub queued_sounds: AtomicU64,
    pub queue_overflows: AtomicU64,
    pub output_restarts: AtomicU64,
    rendered: AtomicU64,
    total_us: AtomicU64,
    max_us: AtomicU64,
    buckets: [AtomicU64; 7],
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub app_version: &'static str,
    pub architecture: &'static str,
    pub input_permission: bool,
    pub audio_ready: bool,
    pub output_sample_rate: u32,
    pub microphone_state: u16,
    pub secure_input: bool,
    pub suspended: bool,
    pub pause_reason: Option<String>,
    pub loaded_audio_bytes: usize,
    pub installed_pack_versions: usize,
    pub presses: u64,
    pub releases: u64,
    pub paused_events: u64,
    pub queued_sounds: u64,
    pub rendered_sounds: u64,
    pub queue_overflows: u64,
    pub output_restarts: u64,
    pub callback_mean_ms: f64,
    pub callback_max_ms: f64,
    pub callback_buckets: [u64; 7],
    pub measurement_scope: &'static str,
}

impl Metrics {
    pub fn rendered(&self, delay: Duration) {
        let micros = delay.as_micros().min(u64::MAX as u128) as u64;
        self.total_us.fetch_add(micros, Relaxed);
        self.max_us.fetch_max(micros, Relaxed);
        let bucket = [1000, 2000, 5000, 10000, 20000, 50000]
            .iter()
            .position(|bound| micros <= *bound)
            .unwrap_or(6);
        self.buckets[bucket].fetch_add(1, Relaxed);
        self.rendered.fetch_add(1, Relaxed);
    }

    pub fn report(&self, controller: &crate::engine::Controller) -> Report {
        let state = controller.snapshot();
        let rendered = self.rendered.load(Relaxed);
        Report {
            app_version: env!("CARGO_PKG_VERSION"),
            architecture: std::env::consts::ARCH,
            input_permission: state.runtime.input_permission,
            audio_ready: state.runtime.audio_ready,
            output_sample_rate: state.runtime.output_sample_rate,
            microphone_state: state.runtime.microphone,
            secure_input: state.runtime.secure_input,
            suspended: state.runtime.suspended,
            pause_reason: state.pause_reason,
            loaded_audio_bytes: controller.loaded_audio_bytes(),
            installed_pack_versions: controller.library.catalog().len(),
            presses: self.presses.load(Relaxed),
            releases: self.releases.load(Relaxed),
            paused_events: self.paused_events.load(Relaxed),
            queued_sounds: self.queued_sounds.load(Relaxed),
            rendered_sounds: rendered,
            queue_overflows: self.queue_overflows.load(Relaxed),
            output_restarts: self.output_restarts.load(Relaxed).saturating_sub(1),
            callback_mean_ms: self.total_us.load(Relaxed) as f64 / rendered.max(1) as f64 / 1000.0,
            callback_max_ms: self.max_us.load(Relaxed) as f64 / 1000.0,
            callback_buckets: std::array::from_fn(|i| self.buckets[i].load(Relaxed)),
            measurement_scope: "Since launch. Native event callback to first nonzero audio output callback; excludes explicit previews. Buckets: <=1, <=2, <=5, <=10, <=20, <=50, >50 ms. Not acoustic latency. No typed text, key identities, event history, app identities, or paths are included. Nothing is transmitted.",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn delays_are_aggregated_without_an_event_history() {
        let metrics = Metrics::default();
        for micros in [500, 1000, 2001, 9000, 51000] {
            metrics.rendered(Duration::from_micros(micros));
        }
        assert_eq!(metrics.rendered.load(Relaxed), 5);
        assert_eq!(metrics.max_us.load(Relaxed), 51000);
        assert_eq!(
            metrics
                .buckets
                .iter()
                .map(|v| v.load(Relaxed))
                .collect::<Vec<_>>(),
            [2, 0, 1, 1, 0, 0, 1]
        );
    }
}
