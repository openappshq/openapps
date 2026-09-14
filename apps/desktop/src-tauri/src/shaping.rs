use crate::model::Preset;
use biquad::{Biquad, Coefficients, DirectForm1, Q_BUTTERWORTH_F32, ToHertz, Type};
use rodio::{ChannelCount, SampleRate, Source, buffer::SamplesBuffer};
use std::{collections::HashMap, sync::OnceLock, time::Duration};

fn key_pan(key: &str) -> f32 {
    static POSITIONS: OnceLock<HashMap<String, f32>> = OnceLock::new();
    *POSITIONS
        .get_or_init(|| {
            let rows: Vec<Vec<(String, String, f32)>> = serde_json::from_str(include_str!(
                "../../../../packages/keyboard-layout/src/layout.json"
            ))
            .expect("bundled keyboard layout");
            let mut positions = HashMap::new();
            for row in rows {
                let total: f32 = row.iter().map(|k| k.2).sum();
                let mut x = 0.0;
                for (code, _, width) in row {
                    positions.insert(code, (x + width / 2.0) / total * 2.0 - 1.0);
                    x += width;
                }
            }
            positions
        })
        .get(key)
        .unwrap_or(&0.0)
}

pub fn shape(sample: SamplesBuffer, preset: &Preset, key: &str) -> Box<dyn Source + Send> {
    let pitched = sample.speed(2.0_f32.powf(preset.pitch / 12.0));
    if preset.tone == 0.0 && preset.width == 0.0 {
        return Box::new(pitched);
    }
    let channels = pitched.channels().get() as usize;
    let db = preset.tone * 0.06;
    let filters = if db == 0.0 {
        vec![]
    } else {
        let coefficients = Coefficients::<f32>::from_params(
            Type::HighShelf(db),
            (pitched.sample_rate().get() as f32).hz(),
            1500.hz(),
            Q_BUTTERWORTH_F32,
        )
        .expect("validated audio sample rate");
        (0..channels)
            .map(|_| DirectForm1::new(coefficients))
            .collect()
    };
    Box::new(Shaped {
        source: pitched,
        filters,
        pan: key_pan(key) * preset.width / 100.0,
        headroom: 10.0_f32.powf(-db.max(0.0) / 20.0),
        output: [0.0; 2],
        index: 2,
    })
}

struct Shaped<S> {
    source: S,
    filters: Vec<DirectForm1<f32>>,
    pan: f32,
    headroom: f32,
    output: [f32; 2],
    index: usize,
}
impl<S: Source> Iterator for Shaped<S> {
    type Item = f32;
    fn next(&mut self) -> Option<f32> {
        let output_channels = self.channels().get() as usize;
        if self.index >= output_channels {
            let channels = self.source.channels().get() as usize;
            for channel in 0..channels {
                let sample = self.source.next()?;
                self.output[channel] = self
                    .filters
                    .get_mut(channel)
                    .map_or(sample, |filter| filter.run(sample))
                    * self.headroom;
            }
            // Equal-power panning follows Web Audio's mono/stereo behavior.
            let [left, right] = self.output;
            self.output = if self.pan == 0.0 {
                [left, right]
            } else if channels == 1 {
                let angle = (self.pan + 1.0) * std::f32::consts::FRAC_PI_4;
                [left * angle.cos(), left * angle.sin()]
            } else if self.pan <= 0.0 {
                let angle = (self.pan + 1.0) * std::f32::consts::FRAC_PI_2;
                [left + right * angle.cos(), right * angle.sin()]
            } else {
                let angle = self.pan * std::f32::consts::FRAC_PI_2;
                [left * angle.cos(), right + left * angle.sin()]
            };
            self.index = 0;
        }
        let value = self.output[self.index];
        self.index += 1;
        Some(value)
    }
}
impl<S: Source> Source for Shaped<S> {
    fn current_span_len(&self) -> Option<usize> {
        None
    }
    fn channels(&self) -> ChannelCount {
        if self.pan == 0.0 {
            self.source.channels()
        } else {
            ChannelCount::new(2).unwrap()
        }
    }
    fn sample_rate(&self) -> SampleRate {
        self.source.sample_rate()
    }
    fn total_duration(&self) -> Option<Duration> {
        self.source.total_duration()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Preferences;
    fn clip() -> SamplesBuffer {
        SamplesBuffer::new(
            ChannelCount::new(2).unwrap(),
            SampleRate::new(48000).unwrap(),
            vec![0.2, 0.4, -0.2, -0.4],
        )
    }
    #[test]
    fn neutral_is_unchanged_and_panning_preserves_energy() {
        let mut preset = Preferences::default().presets.remove(0);
        assert_eq!(
            shape(clip(), &preset, "KeyA").collect::<Vec<_>>(),
            clip().collect::<Vec<_>>()
        );
        preset.width = 100.0;
        assert!(key_pan("KeyA") < 0.0 && key_pan("Enter") > 0.0);
        let left: Vec<_> = shape(clip(), &preset, "KeyA").collect();
        let right: Vec<_> = shape(clip(), &preset, "Enter").collect();
        assert!(left[0] > 0.2 && left[1] < 0.4);
        assert!(right[0] < 0.2 && right[1] > 0.4);
        for tone in [-100.0, 100.0] {
            preset.tone = tone;
            assert!(
                shape(clip(), &preset, "Space")
                    .all(|sample| sample.is_finite() && sample.abs() < 1.0)
            );
        }
        preset.pitch = 6.0;
        assert!(shape(clip(), &preset, "Space").sample_rate().get() > 48000);
    }
    #[test]
    fn legacy_presets_default_to_neutral_and_reject_invalid_tuning() {
        let preferences = Preferences::default();
        let mut value = serde_json::to_value(&preferences).unwrap();
        for name in ["tone", "pitch", "width"] {
            value["presets"][0].as_object_mut().unwrap().remove(name);
        }
        let mut migrated: Preferences = serde_json::from_value(value).unwrap();
        assert_eq!(migrated.presets[0].tone, 0.0);
        assert!(migrated.validate_shape().is_ok());
        migrated.presets[0].pitch = 7.0;
        assert!(migrated.validate_shape().is_err());
        migrated.presets[0].pitch = f32::NAN;
        assert!(migrated.validate_shape().is_err());
    }
}
