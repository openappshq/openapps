import { expect, test, vi } from "vite-plus/test";
import { createAudio } from "./audio";
import { defaults } from "./keyboard";

test("the first key waits for audio to resume, and muting cancels it", async () => {
  const source = {
    playbackRate: { value: 1 },
    connect: vi.fn(),
    start: vi.fn(),
    stop: vi.fn(),
  };
  let resume!: () => void;
  class AudioContext {
    state = "suspended";
    destination = {};
    resume() {
      return new Promise<void>((resolve) => {
        resume = () => {
          this.state = "running";
          resolve();
        };
      });
    }
    async decodeAudioData() {
      return {
        numberOfChannels: 1,
        sampleRate: 1000,
        getChannelData: () => new Float32Array(1000).fill(0.1),
      };
    }
    createBufferSource() {
      return source;
    }
    createGain() {
      return { gain: { value: 1 }, connect: vi.fn() };
    }
  }
  vi.stubGlobal("AudioContext", AudioContext);
  vi.stubGlobal("fetch", async () => new Response(new ArrayBuffer(1)));
  try {
    const audio = createAudio();
    const voice = { packId: defaults.packId, volume: 100 };
    await audio.load(voice.packId);
    audio.configure(65, true);
    const ready = audio.unlock([voice.packId]);
    expect(audio.play(voice, "KeyA", true, defaults)).toBe(source);
    expect(source.start).toHaveBeenCalledOnce();
    audio.configure(65, false);
    expect(source.stop).toHaveBeenCalledOnce();
    resume();
    await ready;
    expect(audio.play(voice, "KeyB", true, defaults)).toBeUndefined();
  } finally {
    vi.unstubAllGlobals();
  }
});
