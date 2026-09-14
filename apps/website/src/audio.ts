import { keyPan } from "@openklack/keyboard-layout";
import { getPack, sampleFor } from "./soundpacks";
import type { KeyVoice, Settings } from "./keyboard";

export type PlayingSound = AudioBufferSourceNode;
type Recording = { buffer: AudioBuffer; gain: number };

export function recordingGain(channels: Float32Array[], rate: number, regions: [number, number][]) {
  let peak = 0;
  const levels = regions
    .map(([start, duration]) => {
      const begin = Math.round((start * rate) / 1000);
      const end = begin + Math.round((duration * rate) / 1000);
      let energy = 0,
        count = 0;
      for (const channel of channels)
        for (let i = begin; i < Math.min(end, channel.length); i++) {
          const value = channel[i]!;
          peak = Math.max(peak, Math.abs(value));
          energy += value * value;
          count++;
        }
      return count ? Math.sqrt(energy / count) : 0;
    })
    .filter((level) => level > 0)
    .sort((a, b) => a - b);
  return Math.max(
    0.05,
    Math.min(
      8,
      0.08 / Math.max(levels[Math.floor(levels.length / 2)] ?? 0.08, 0.001),
      0.8 / Math.max(peak, 0.001),
    ),
  );
}

export function createAudio() {
  const cache = new Map<string, Recording>();
  const loading = new Map<string, Promise<Recording>>();
  const playing = new Set<PlayingSound>();
  let context: AudioContext | undefined;
  let enabled = false,
    volume = 0.45;
  const engine = () => (context ??= new AudioContext({ latencyHint: "interactive" }));
  function load(packId: string): Promise<Recording> {
    const cached = cache.get(packId);
    if (cached) return Promise.resolve(cached);
    const pending = loading.get(packId);
    if (pending) return pending;
    const pack = getPack(packId);
    const ready = (async () => {
      for (const format of ["ogg", "mp3"]) {
        try {
          const response = await fetch(`/sounds/${pack.id}.${format}`);
          if (!response.ok) continue;
          const buffer = await engine().decodeAudioData(await response.arrayBuffer());
          const gain = recordingGain(
            Array.from({ length: buffer.numberOfChannels }, (_, i) => buffer.getChannelData(i)),
            buffer.sampleRate,
            Object.values(pack.sprite),
          );
          const recording = { buffer, gain };
          cache.set(packId, recording);
          return recording;
        } catch {
          /* Try the other supported recording format. */
        }
      }
      throw new Error(
        `Couldn’t load ${pack.brand} ${pack.name}. Check your connection and try again.`,
      );
    })().finally(() => loading.delete(packId));
    loading.set(packId, ready);
    return ready;
  }
  return {
    load,
    async unlock(packIds: string[]) {
      await Promise.all([engine().resume(), ...[...new Set(packIds)].map(load)]);
    },
    configure(nextVolume: number, nextEnabled: boolean) {
      volume = nextVolume / 100;
      if (enabled && !nextEnabled) playing.forEach((source) => source.stop());
      enabled = nextEnabled;
    },
    play(
      voice: KeyVoice,
      code: string,
      down: boolean,
      settings: Pick<Settings, "variation" | "releaseVolume" | "tone" | "pitch" | "width">,
      preview = false,
    ): PlayingSound | undefined {
      if ((!enabled && !preview) || context?.state !== "running") return;
      const recording = cache.get(voice.packId);
      const pack = getPack(voice.packId);
      const name = sampleFor(pack, code, down, settings.variation);
      if (!recording || !name) return;
      const [offset, duration] = pack.sprite[name]!;
      const source = context.createBufferSource();
      source.buffer = recording.buffer;
      source.playbackRate.value = 2 ** (settings.pitch / 12);
      const gain = context.createGain();
      const db = settings.tone * 0.06;
      gain.gain.value =
        ((volume * recording.gain * voice.volume) / 100) *
        (down ? 1 : settings.releaseVolume / 100) *
        10 ** (-Math.max(db, 0) / 20);
      const nodes: AudioNode[] = [source];
      if (db) {
        const filter = context.createBiquadFilter();
        filter.type = "highshelf";
        filter.frequency.value = 1500;
        filter.gain.value = db;
        nodes.push(filter);
      }
      if (settings.width) {
        const pan = context.createStereoPanner();
        pan.pan.value = (keyPan(code) * settings.width) / 100;
        nodes.push(pan);
      }
      nodes.push(gain);
      nodes.forEach((node, i) => node.connect(nodes[i + 1] ?? context!.destination));
      source.onended = () => {
        playing.delete(source);
        nodes.forEach((node) => node.disconnect());
      };
      if (playing.size >= 128) {
        const oldest = playing.values().next().value!;
        oldest.stop();
        playing.delete(oldest);
      }
      playing.add(source);
      source.start(0, offset / 1000, duration / 1000);
      return source;
    },
    stop(sound: PlayingSound) {
      if (playing.has(sound)) sound.stop();
    },
  };
}
