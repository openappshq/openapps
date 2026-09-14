use crate::model::{Pack, Preferences};
use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Source, buffer::SamplesBuffer};
use std::{
    collections::{BTreeMap, HashMap},
    fs::File,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

pub struct PreparedPack {
    pub keys: BTreeMap<String, (Vec<SamplesBuffer>, Vec<SamplesBuffer>)>,
    pub gain: f32,
    pub decoded_bytes: usize,
}

pub struct Playback {
    pub revision: u64,
    pub prefs: Preferences,
    pub packs: HashMap<String, Arc<PreparedPack>>,
}

pub const MAX_DECODED_BYTES: usize = 128 * 1024 * 1024;

pub fn decode_pack(pack: &Pack, directory: &Path) -> Result<PreparedPack, String> {
    pack.validate()?;
    let mut regions = HashMap::new();
    let mut decoded_bytes = 0usize;
    if pack.files.is_empty() {
        let filename = pack
            .sprite_file
            .clone()
            .unwrap_or_else(|| format!("{}.ogg", pack.id));
        let (channels, rate, samples) = read_samples(&directory.join(filename), 180)?;
        for (name, [start, duration]) in &pack.sprite {
            if !start.is_finite()
                || !duration.is_finite()
                || !(0.0..=180_000.0).contains(start)
                || *duration <= 0.0
                || *duration > 5000.0
            {
                return Err("A sound pack contains invalid clip boundaries.".into());
            }
            let begin = ((*start / 1000.0) * f64::from(rate.get())).round() as usize
                * channels.get() as usize;
            let length = ((*duration / 1000.0) * f64::from(rate.get())).round() as usize
                * channels.get() as usize;
            let clip = samples
                .get(begin..begin + length)
                .filter(|s| !s.is_empty())
                .ok_or("A sound clip extends past its recording.")?;
            decoded_bytes += std::mem::size_of_val(clip);
            if decoded_bytes > MAX_DECODED_BYTES {
                return Err("The decoded pack is larger than 128 MB.".into());
            }
            regions.insert(
                name.clone(),
                SamplesBuffer::new(channels, rate, clip.to_vec()),
            );
        }
    } else {
        for (name, filename) in &pack.files {
            let (channels, rate, samples) = read_samples(&directory.join(filename), 5)?;
            decoded_bytes += samples.len() * std::mem::size_of::<f32>();
            if decoded_bytes > MAX_DECODED_BYTES {
                return Err("The decoded pack is larger than 128 MB.".into());
            }
            regions.insert(name.clone(), SamplesBuffer::new(channels, rate, samples));
        }
    }
    let mut levels = vec![];
    let mut peak = 0.0_f32;
    for sample in regions.values() {
        let mut count = 0usize;
        let mut energy = 0.0_f64;
        for value in sample.clone() {
            if !value.is_finite() {
                return Err("A sound clip contains invalid samples.".into());
            }
            count += 1;
            peak = peak.max(value.abs());
            energy += f64::from(value).powi(2);
        }
        if energy > 0.0 && count > 0 {
            levels.push((energy / count as f64).sqrt() as f32);
        }
    }
    levels.sort_by(f32::total_cmp);
    let typical = levels.get(levels.len() / 2).copied().unwrap_or(0.08);
    let gain = (0.08 / typical.max(0.001))
        .min(0.8 / peak.max(0.001))
        .clamp(0.05, 8.0);
    let mut keys = BTreeMap::new();
    for (key, phases) in &pack.sounds {
        let resolve = |names: &[String]| -> Result<Vec<SamplesBuffer>, String> {
            names
                .iter()
                .map(|name| {
                    regions
                        .get(name)
                        .cloned()
                        .ok_or_else(|| "A sound mapping refers to a missing clip.".into())
                })
                .collect()
        };
        keys.insert(key.clone(), (resolve(&phases.down)?, resolve(&phases.up)?));
    }
    Ok(PreparedPack {
        keys,
        gain,
        decoded_bytes,
    })
}

fn read_samples(
    path: &Path,
    seconds: usize,
) -> Result<(rodio::ChannelCount, rodio::SampleRate, Vec<f32>), String> {
    if !path
        .symlink_metadata()
        .map_err(|e| e.to_string())?
        .file_type()
        .is_file()
    {
        return Err("Audio must be stored in a regular file.".into());
    }
    let file = File::open(path).map_err(|e| format!("Cannot open sound pack: {e}"))?;
    let decoder = Decoder::try_from(file).map_err(|e| format!("Cannot decode sound pack: {e}"))?;
    let channels = decoder.channels();
    let rate = decoder.sample_rate();
    if channels.get() > 2 || !(8000..=192000).contains(&rate.get()) {
        return Err("Use mono or stereo audio between 8 and 192 kHz.".into());
    }
    let limit = (rate.get() as usize * channels.get() as usize * seconds).min(32 * 1024 * 1024);
    let samples: Vec<f32> = decoder.take(limit + 1).collect();
    if samples.len() > limit || samples.is_empty() {
        return Err(format!(
            "Audio must be nonempty and no longer than {seconds} seconds."
        ));
    }
    Ok((channels, rate, samples))
}

impl Playback {
    pub fn sample(
        &self,
        app: &str,
        key: &str,
        down: bool,
        variant: usize,
    ) -> Option<(Box<dyn Source + Send>, f32)> {
        let preset = self.prefs.preset(app);
        let assignment = preset.overrides.get(key);
        let id = assignment.map_or(&preset.pack_id, |v| &v.pack_id);
        let pack = self.packs.get(id)?;
        let phases = pack.keys.get(key).or_else(|| pack.keys.get("default"))?;
        let options = if down { &phases.0 } else { &phases.1 };
        let index = if preset.variation {
            variant % options.len().max(1)
        } else {
            0
        };
        let sample = options.get(index)?.clone();
        let gain = pack.gain * preset.volume / 100.0
            * assignment.map_or(1.0, |v| v.volume / 100.0)
            * if down {
                1.0
            } else {
                preset.release_volume / 100.0
            };
        Some((crate::shaping::shape(sample, preset, key), gain))
    }
}

pub fn open_output(failed: Arc<AtomicBool>) -> Result<MixerDeviceSink, String> {
    use rodio::cpal::BufferSize;
    let builder = || {
        let failed = failed.clone();
        DeviceSinkBuilder::from_default_device().map(|builder| {
            builder.with_error_callback(move |_| {
                failed.store(true, Ordering::Relaxed);
            })
        })
    };
    let mut sink = builder()
        .map_err(|e| e.to_string())?
        .with_buffer_size(BufferSize::Fixed(256))
        .open_stream()
        .or_else(|_| builder()?.open_stream())
        .map_err(|e| e.to_string())?;
    sink.log_on_drop(false);
    Ok(sink)
}

#[derive(Default)]
pub struct Voices {
    pub generation: AtomicU64,
    sequence: AtomicU64,
}

pub struct Cancellable<S> {
    source: S,
    voices: Arc<Voices>,
    started: u64,
    sequence: u64,
    measurement: Option<(Instant, Arc<crate::diagnostics::Metrics>)>,
}
impl<S> Cancellable<S> {
    pub fn new(source: S, voices: Arc<Voices>) -> Self {
        let started = voices.generation.load(Ordering::Relaxed);
        let sequence = voices.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        Self {
            source,
            voices,
            started,
            sequence,
            measurement: None,
        }
    }
    pub fn measured(
        mut self,
        received: Instant,
        metrics: Arc<crate::diagnostics::Metrics>,
    ) -> Self {
        self.measurement = Some((received, metrics));
        self
    }
}
impl<S: Source> Iterator for Cancellable<S> {
    type Item = f32;
    fn next(&mut self) -> Option<f32> {
        // ponytail: cap overlap at 128 voices; replace oldest tails, never delay a new press.
        if self.voices.generation.load(Ordering::Relaxed) != self.started
            || self
                .voices
                .sequence
                .load(Ordering::Relaxed)
                .wrapping_sub(self.sequence)
                >= 128
        {
            None
        } else {
            let value = self.source.next()?;
            if value.abs() > 0.00001
                && let Some((received, metrics)) = self.measurement.take()
            {
                metrics.rendered(received.elapsed());
            }
            Some(value)
        }
    }
}
impl<S: Source> Source for Cancellable<S> {
    fn current_span_len(&self) -> Option<usize> {
        self.source.current_span_len()
    }
    fn channels(&self) -> rodio::ChannelCount {
        self.source.channels()
    }
    fn sample_rate(&self) -> rodio::SampleRate {
        self.source.sample_rate()
    }
    fn total_duration(&self) -> Option<Duration> {
        self.source.total_duration()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn excessive_overlap_replaces_old_tails_and_cancellation_stops_every_voice() {
        let voices = Arc::new(Voices::default());
        let mut sources = (0..129)
            .map(|_| {
                Cancellable::new(
                    SamplesBuffer::new(
                        1.try_into().unwrap(),
                        8000.try_into().unwrap(),
                        vec![0.1; 100],
                    ),
                    voices.clone(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(sources[0].next(), None);
        assert_eq!(sources[128].next(), Some(0.1));
        voices.generation.fetch_add(1, Ordering::Relaxed);
        assert!(sources.iter_mut().all(|s| s.next().is_none()));
    }
    #[test]
    fn all_recorded_regions_decode_and_empty_release_stays_silent() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let catalog: Vec<Pack> = serde_json::from_slice(
            &std::fs::read(root.join("packages/soundpacks/catalog.json")).unwrap(),
        )
        .unwrap();
        let mut clips = 0;
        for pack in &catalog {
            let decoded = decode_pack(pack, &root.join("packages/soundpacks/sounds"))
                .unwrap_or_else(|e| panic!("{}: {e}", pack.id));
            assert!(decoded.gain.is_finite());
            if !pack.supports_key_up {
                assert!(decoded.keys.values().all(|(_, up)| up.is_empty()));
            }
            clips += pack.sprite.len();
        }
        assert_eq!(clips, 793);
    }

    #[test]
    #[ignore = "plays a quiet sample on the current output and waits 30 seconds to check idle recovery"]
    fn native_output_starts_after_idle() {
        use std::sync::mpsc;
        use std::time::Instant;
        struct Probe {
            source: SamplesBuffer,
            sender: Option<mpsc::Sender<Duration>>,
            queued: Instant,
        }
        impl Iterator for Probe {
            type Item = f32;
            fn next(&mut self) -> Option<f32> {
                let value = self.source.next()?;
                if value.abs() > 0.00001
                    && let Some(sender) = self.sender.take()
                {
                    let _ = sender.send(self.queued.elapsed());
                }
                Some(value * 0.1)
            }
        }
        impl Source for Probe {
            fn current_span_len(&self) -> Option<usize> {
                self.source.current_span_len()
            }
            fn channels(&self) -> rodio::ChannelCount {
                self.source.channels()
            }
            fn sample_rate(&self) -> rodio::SampleRate {
                self.source.sample_rate()
            }
            fn total_duration(&self) -> Option<Duration> {
                self.source.total_duration()
            }
        }
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let catalog: Vec<Pack> = serde_json::from_slice(
            &std::fs::read(root.join("packages/soundpacks/catalog.json")).unwrap(),
        )
        .unwrap();
        let pack = decode_pack(
            catalog.iter().find(|p| p.id == "novelkeys-cream").unwrap(),
            &root.join("packages/soundpacks/sounds"),
        )
        .unwrap();
        let output =
            open_output(Arc::new(AtomicBool::new(false))).expect("a working physical audio output");
        for idle in [0, 30] {
            std::thread::sleep(Duration::from_secs(idle));
            let (sender, receiver) = mpsc::channel();
            output.mixer().add(Probe {
                source: pack.keys["default"].0[0].clone(),
                sender: Some(sender),
                queued: Instant::now(),
            });
            let delay = receiver
                .recv_timeout(Duration::from_millis(250))
                .expect("first sample reached the actual output callback");
            println!(
                "idle_seconds={idle} first_nonzero_callback_ms={:.3} sample_rate={}",
                delay.as_secs_f64() * 1000.0,
                output.config().sample_rate()
            );
            assert!(
                delay < Duration::from_millis(30),
                "measured scheduling delay: {delay:?}"
            );
        }
    }
}
