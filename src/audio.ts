import sprite from "./sound-sprite.json";
import { profiles, type Profile } from "./keyboard";

// All profiles are pitch/EQ treatments of the reference recording, not separate switch recordings.
export function createAudio() {
  let context: AudioContext | undefined;
  let buffer: AudioBuffer | undefined;
  let loading: Promise<void> | undefined;
  let master: GainNode | undefined;
  let volume = 0.65;
  let muted = true;
  const voices = new Map<Profile, BiquadFilterNode>();

  async function unlock() {
    if (!context) {
      context = new AudioContext({ latencyHint: "interactive" });
      master = context.createGain();
      master.gain.value = muted ? 0 : volume * 2;
      master.connect(context.destination);
      for (const [name, profile] of Object.entries(profiles)) {
        const filter = context.createBiquadFilter();
        filter.type = "lowpass";
        filter.frequency.value = profile.frequency;
        filter.connect(master);
        voices.set(name as Profile, filter);
      }
    }
    const resume = context.resume();
    if (!loading)
      loading = fetch("/keyboard/switches.ogg")
        .then((response) => {
          if (!response.ok) throw new Error("Sound could not be loaded.");
          return response.arrayBuffer();
        })
        .then((data) => context!.decodeAudioData(data))
        .then((decoded) => {
          buffer = decoded;
        })
        .catch((error) => {
          loading = undefined;
          throw error;
        });
    await Promise.all([resume, loading]);
  }

  return {
    unlock,
    configure(nextVolume: number, enabled: boolean) {
      volume = nextVolume / 100;
      muted = !enabled;
      if (context && master)
        master.gain.setTargetAtTime(muted ? 0 : volume * 2, context.currentTime, 0.015);
    },
    play(code: string, down: boolean, profile: Profile) {
      if (!context || !buffer || muted || context.state !== "running") return;
      const aliases: Record<string, keyof typeof sprite> = {
        MetaLeft: "AltLeft",
        MetaRight: "AltLeft",
        AltRight: "AltLeft",
        ControlRight: "ControlLeft",
      };
      const ranges = sprite[(aliases[code] ?? code) as keyof typeof sprite] ?? sprite.KeyA;
      const [start, end] = ranges[down ? 0 : 1];
      const source = context.createBufferSource();
      source.buffer = buffer;
      source.playbackRate.value = profiles[profile].rate;
      source.connect(voices.get(profile)!);
      source.onended = () => source.disconnect();
      source.start(0, start / 1000, (end - start) / 1000);
    },
  };
}
