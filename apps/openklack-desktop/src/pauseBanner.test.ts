import { expect, test } from "vite-plus/test";
import { RESUMABLE_REASONS, resumedBannerText } from "./pauseBanner";

test("a resume for a muted app names the app, or falls back when the rule has no name", () => {
  expect(resumedBannerText("Paused for this app", "Zoom")).toBe("Playing in Zoom anyway");
  expect(resumedBannerText("Paused for this app", "  ")).toBe("Playing in this app anyway");
  expect(resumedBannerText("Paused for this app")).toBe("Playing in this app anyway");
});

test("a resume for the microphone says so, whether it is in use or still being checked", () => {
  expect(resumedBannerText("Microphone in use")).toBe("Playing while the microphone is in use");
  expect(resumedBannerText("Checking microphone activity", "Zoom")).toBe(
    "Playing while the microphone is in use",
  );
});

test("every resumable pause has a banner line", () => {
  for (const reason of RESUMABLE_REASONS) expect(resumedBannerText(reason)).toMatch(/^Playing /);
});
