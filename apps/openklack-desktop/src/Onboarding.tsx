import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Button } from "@heroui/react";
import { KeyRound, Menu, Power, ShieldCheck, Volume2 } from "lucide-react";
import klackMark from "../../../design/assets/openklack/symbol-paper.svg";

const STEPS = ["Welcome", "Keyboard access", "Tips"] as const;

const step = {
  initial: { opacity: 0, transform: "translateY(8px)" },
  animate: { opacity: 1, transform: "translateY(0)" },
  exit: { opacity: 0, transform: "translateY(-6px)" },
};

/**
 * The setup guide: three short steps over the settings window. Skippable at any point, and
 * never in the way of the menu bar. Input Monitoring is read live from the snapshot, which the
 * native bridge refreshes every second while the app runs.
 */
export function Onboarding({
  official,
  inputPermission,
  busy,
  onRequestPermission,
  onDone,
}: {
  /** An official build: the trial and the license are worth a mention. */
  official: boolean;
  inputPermission: boolean;
  busy: boolean;
  onRequestPermission: () => void;
  /** Finished or skipped; the caller remembers it. */
  onDone: () => void;
}) {
  const [index, setIndex] = useState(0);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    panel.current?.focus();
  }, [index]);
  const last = index === STEPS.length - 1;
  return (
    <div
      className="onboarding"
      role="dialog"
      aria-modal="true"
      aria-labelledby="onboarding-title"
      onKeyDown={(event) => {
        if (event.key === "Escape") onDone();
      }}
    >
      <div className="onboarding-panel" ref={panel} tabIndex={-1}>
        <div className="onboarding-heading">
          <span className="eyebrow" aria-live="polite">
            Step {index + 1} of {STEPS.length} · {STEPS[index]}
          </span>
          <Button variant="ghost" onPress={onDone}>
            Skip
          </Button>
        </div>
        <AnimatePresence mode="wait" initial={false}>
          <motion.div key={index} className="onboarding-step" {...step}>
            {index === 0 && (
              <>
                <div className="brand-mark">
                  <img src={klackMark} alt="" />
                </div>
                <h2 id="onboarding-title">Mechanical keyboard sound, everywhere you type</h2>
                <p>
                  OpenKlack plays a keyboard sound for every key you press, in any app, from the
                  menu bar. Your typing is never saved or sent anywhere.
                </p>
                {official && (
                  <p>
                    Your free 3-day trial started when you opened the app. No signup, nothing to set
                    up.
                  </p>
                )}
              </>
            )}
            {index === 1 && (
              <>
                <h2 id="onboarding-title">Let OpenKlack hear your keyboard</h2>
                <p>
                  macOS only lets an app notice key presses in other apps with the Input Monitoring
                  permission. OpenKlack uses it for the sounds and nothing else.
                </p>
                <div className="onboarding-permission" role="status">
                  {inputPermission ? (
                    <span data-granted="true">Granted ✓</span>
                  ) : (
                    <>
                      <ShieldCheck size={18} aria-hidden="true" />
                      <span>Not granted yet</span>
                      <Button variant="primary" isDisabled={busy} onPress={onRequestPermission}>
                        Open System Settings
                      </Button>
                    </>
                  )}
                </div>
                <p className="onboarding-note">
                  {inputPermission
                    ? "If the sounds don’t start right away, quit and reopen OpenKlack: macOS sometimes asks for that after the permission changes."
                    : "In System Settings, turn on OpenKlack under Privacy & Security → Input Monitoring. macOS may ask you to quit and reopen OpenKlack afterwards."}
                </p>
              </>
            )}
            {index === 2 && (
              <>
                <h2 id="onboarding-title">A few things worth knowing</h2>
                <ul className="onboarding-tips">
                  <li>
                    <Volume2 size={18} aria-hidden="true" />
                    <div>
                      <strong>Choose a sound</strong>
                      <p>
                        Pick one beside the keyboard, or Browse all. Star a sound to keep it in the
                        menu bar.
                      </p>
                    </div>
                  </li>
                  <li>
                    <Menu size={18} aria-hidden="true" />
                    <div>
                      <strong>It lives in the menu bar</strong>
                      <p>
                        Mute, volume and starred sounds are there. Close this window and keep
                        typing.
                      </p>
                    </div>
                  </li>
                  {official && (
                    <li>
                      <KeyRound size={18} aria-hidden="true" />
                      <div>
                        <strong>Your trial and license</strong>
                        <p>
                          Settings → License shows the days left and where to paste your key after
                          you buy.
                        </p>
                      </div>
                    </li>
                  )}
                  {official && (
                    <li>
                      <Power size={18} aria-hidden="true" />
                      <div>
                        <strong>Starts with your Mac</strong>
                        <p>OpenKlack opens at login. Change this in Settings.</p>
                      </div>
                    </li>
                  )}
                </ul>
              </>
            )}
          </motion.div>
        </AnimatePresence>
        <div className="onboarding-actions">
          {index > 0 && (
            <Button variant="ghost" onPress={() => setIndex(index - 1)}>
              Back
            </Button>
          )}
          <Button variant="primary" onPress={() => (last ? onDone() : setIndex(index + 1))}>
            {last ? "Done" : "Continue"}
          </Button>
        </div>
      </div>
    </div>
  );
}
