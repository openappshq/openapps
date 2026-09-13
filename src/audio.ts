import { Howl, Howler } from "howler";
import { getPack, sampleFor } from "./soundpacks";
import type { KeyVoice, Settings } from "./keyboard";

export type PlayingSound = { packId: string; id: number };

export function createAudio() {
  const cache = new Map<string, { howl: Howl; ready: Promise<Howl> }>();
  let enabled = false;

  function load(packId: string) {
    const existing = cache.get(packId);
    if (existing) return existing.ready;
    const pack = getPack(packId);
    const howl = new Howl({
      src: [`/sounds/${pack.id}.ogg`, `/sounds/${pack.id}.mp3`],
      sprite: pack.sprite,
      preload: false,
      pool: 16,
    });
    const ready = new Promise<Howl>((resolve, reject) => {
      howl.once("load", () => resolve(howl));
      howl.once("loaderror", () => {
        cache.delete(packId);
        howl.unload();
        reject(
          new Error(
            `Couldn’t load ${pack.brand} ${pack.name}. Check your connection and try again.`,
          ),
        );
      });
    });
    cache.set(packId, { howl, ready });
    howl.load();
    return ready;
  }

  return {
    load,
    async unlock(packIds: string[]) {
      const loading = [...new Set(packIds)].map(load);
      await Promise.all([...loading, Howler.ctx?.resume()]);
    },
    configure(volume: number, nextEnabled: boolean) {
      Howler.volume(volume / 100);
      if (enabled && !nextEnabled) Howler.stop();
      enabled = nextEnabled;
    },
    play(
      voice: KeyVoice,
      code: string,
      down: boolean,
      settings: Pick<Settings, "variation" | "releaseVolume">,
      preview = false,
    ): PlayingSound | undefined {
      if (!enabled && !preview) return;
      const howl = cache.get(voice.packId)?.howl;
      if (!howl || howl.state() !== "loaded") return;
      const sample = sampleFor(getPack(voice.packId), code, down, settings.variation);
      if (!sample) return;
      const id = howl.play(sample);
      howl.volume((voice.volume / 100) * (down ? 1 : settings.releaseVolume / 100), id);
      return { packId: voice.packId, id };
    },
    stop(sound: PlayingSound) {
      cache.get(sound.packId)?.howl.stop(sound.id);
    },
  };
}
