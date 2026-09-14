import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button, Input, Label, TextField } from "@heroui/react";
import { BadgeCheck, KeyRound, WifiOff } from "lucide-react";

export type LicenseView = {
  revision: number;
  ready: boolean;
  environment: "test" | "live";
  state:
    | "unlicensed"
    | "trial"
    | "trialEnded"
    | "trialOffline"
    | "clockBehind"
    | "licensed"
    | "grace"
    | "checkRequired"
    | "revoked";
  daysLeft?: number;
  daysOffline?: number;
  coreFeature: boolean;
  clockChanged: boolean;
  journalUnreadable: boolean;
  trialStorageError: boolean;
  graceWarning: boolean;
  checking: boolean;
  lastSuccessAt: number | null;
  lastError: string | null;
  pendingKey: string | null;
  buyUrl: string;
  supportUrl: string;
};

export const PRIVACY_COPY =
  "Official builds include a 3-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use the app are never sent. Builds from source never contact the license service.";

/** "N days left", rounded up; the backend sends 0 in the final 24 hours. */
function trialLeft(daysLeft = 0) {
  if (daysLeft < 1) return "less than a day left";
  return `${daysLeft} ${daysLeft === 1 ? "day" : "days"} left`;
}

export function License({
  onError,
  disabled,
}: {
  onError: (error: string) => void;
  disabled: boolean;
}) {
  const [view, setView] = useState<LicenseView>();
  // `null` until the user types, so a deep link's key shows without being copied into state.
  const [typed, setTyped] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [working, setWorking] = useState(false);
  const accept = useCallback((next: LicenseView) => {
    setView((current) => (current && current.revision > next.revision ? current : next));
  }, []);
  useEffect(() => {
    let disposed = false;
    let off: (() => void) | undefined;
    async function subscribe() {
      off = await listen<LicenseView>("license", ({ payload }) => {
        if (!disposed) accept(payload);
      });
      if (disposed) {
        off();
        return;
      }
      const current = await invoke<LicenseView>("license_status");
      if (!disposed) accept(current);
    }
    void subscribe().catch((error: unknown) => {
      if (!disposed) onError(String(error));
    });
    return () => {
      disposed = true;
      off?.();
    };
  }, [accept, onError]);
  // A deep link only pre-fills the key; the user confirms before anything is sent.
  const pendingKey = view?.pendingKey ?? null;
  const key = typed ?? pendingKey ?? "";

  async function run(
    task: () => Promise<LicenseView | void>,
    done?: string | ((next: LicenseView) => string),
  ) {
    setWorking(true);
    setNotice("");
    try {
      const next = await task();
      if (next) accept(next);
      if (typeof done === "function") {
        if (next) setNotice(done(next));
      } else if (done) setNotice(done);
      return true;
    } catch (error) {
      onError(String(error));
      return false;
    } finally {
      setWorking(false);
    }
  }
  const busy = disabled || working || !!view?.checking;
  const retry = (
    <Button
      variant="secondary"
      isDisabled={busy}
      onPress={() => void run(() => invoke<LicenseView>("reload_license"))}
    >
      {view?.checking ? "Checking…" : "Try again"}
    </Button>
  );

  if (!view || !view.ready)
    return (
      <section className="license" aria-label="License">
        <h2>License</h2>
        {view?.lastError ? (
          <>
            <p className="inline-error" role="alert">
              Couldn’t read your license. {view.lastError}
            </p>
            <div className="actions">{retry}</div>
          </>
        ) : (
          <p role="status">Loading license…</p>
        )}
      </section>
    );

  const trialStates: LicenseView["state"][] = [
    "unlicensed",
    "trial",
    "trialEnded",
    "trialOffline",
    "clockBehind",
  ];
  const inTrial = trialStates.includes(view.state);
  const canEnterKey = inTrial || view.state === "revoked";
  const status: Record<LicenseView["state"], string> = {
    unlicensed: view.trialStorageError
      ? "Your free trial can’t run until OpenKlack can use the Keychain."
      : "Starting your free trial…",
    trial: `Free trial: ${trialLeft(view.daysLeft)}`,
    trialEnded: "Your free trial has ended",
    trialOffline: "Connect to the internet to continue your free trial",
    clockBehind:
      "Your Mac’s clock is behind. Set the correct date and time to keep using your free trial",
    licensed: "Licensed",
    grace: view.graceWarning
      ? `Connect to the internet within ${view.daysLeft ?? 0} ${view.daysLeft === 1 ? "day" : "days"} to keep using OpenKlack.`
      : "Licensed",
    checkRequired: view.clockChanged
      ? "Your Mac’s clock changed. Connect to the internet to verify your license."
      : "Connect to the internet to verify your license.",
    revoked: "This license is no longer active on this Mac.",
  };
  const licensedLook = view.state === "licensed" || (view.state === "grace" && !view.graceWarning);
  const offline =
    view.state === "checkRequired" ||
    view.state === "trialOffline" ||
    (view.state === "grace" && view.graceWarning);
  const warning = offline || !view.coreFeature;

  return (
    <section className="license" aria-label="License">
      <div className="license-heading">
        <h2>License</h2>
        {view.environment === "test" && <span className="eyebrow">Test mode</span>}
      </div>
      <div className="license-status" role="status">
        {licensedLook ? (
          <BadgeCheck size={18} aria-hidden="true" />
        ) : offline ? (
          <WifiOff size={18} aria-hidden="true" />
        ) : (
          <KeyRound size={18} aria-hidden="true" />
        )}
        <p data-warning={warning}>{status[view.state]}</p>
      </div>
      {view.journalUnreadable && (
        <>
          <p className="inline-error" role="alert">
            Couldn’t read license data — checking with the license server… {view.lastError}
          </p>
          <div className="actions">{retry}</div>
        </>
      )}
      {!view.journalUnreadable &&
        view.lastError &&
        (view.state === "checkRequired" || inTrial) && (
          <p className="inline-error" role="alert">
            {view.lastError}
          </p>
        )}
      {notice && (
        <p className="feedback" role="status">
          {notice}
        </p>
      )}
      {(view.state === "trialOffline" ||
        view.state === "clockBehind" ||
        view.state === "checkRequired" ||
        (view.state === "unlicensed" && view.trialStorageError)) && (
        <div className="actions">{retry}</div>
      )}
      {inTrial && (
        <div className="actions">
          <Button
            variant="primary"
            isDisabled={busy}
            onPress={() => void run(() => invoke("open_license_link", { link: "buy" }))}
          >
            Buy for $5
          </Button>
        </div>
      )}
      {view.state === "revoked" && (
        <div className="actions">
          <Button
            variant="primary"
            isDisabled={busy}
            onPress={() => void run(() => invoke("open_license_link", { link: "buy" }))}
          >
            Buy for $5
          </Button>
          <Button
            variant="ghost"
            isDisabled={busy}
            onPress={() => void run(() => invoke("open_license_link", { link: "support" }))}
          >
            Contact support
          </Button>
        </div>
      )}
      {canEnterKey && (
        <form
          className="license-key"
          onSubmit={(event) => {
            event.preventDefault();
            void run(async () => {
              const next = await invoke<LicenseView>("activate_license", { key });
              setTyped(null);
              return next;
            }, "This Mac is licensed.");
          }}
        >
          <TextField
            className="license-field"
            value={key}
            onChange={setTyped}
            isDisabled={busy}
            autoComplete="off"
          >
            <Label>{inTrial ? "Already bought? Paste your license key" : "License key"}</Label>
            <Input placeholder="XXXX-XXXX-XXXX-XXXX" spellCheck={false} />
          </TextField>
          {pendingKey && key === pendingKey && (
            <p className="inline-hint">Activate the key from the link you opened?</p>
          )}
          <div className="actions">
            <Button type="submit" variant="secondary" isDisabled={busy || !key.trim()}>
              {view.state === "revoked" ? "Activate again" : "Activate"}
            </Button>
            {pendingKey && (
              <Button
                variant="ghost"
                isDisabled={busy}
                onPress={() =>
                  void run(async () => {
                    setTyped(null);
                    return invoke<LicenseView>("dismiss_license_key");
                  })
                }
              >
                Not now
              </Button>
            )}
          </div>
        </form>
      )}
      {(view.state === "licensed" || view.state === "grace" || view.state === "revoked") && (
        <div className="actions">
          {view.graceWarning && (
            <Button
              variant="secondary"
              isDisabled={busy}
              onPress={() =>
                void run(() => invoke<LicenseView>("check_license_now"), "License verified.")
              }
            >
              Check now
            </Button>
          )}
          <Button
            variant="ghost"
            isDisabled={busy}
            onPress={() =>
              void run(
                () => invoke<LicenseView>("remove_license"),
                "This Mac was removed from your license.",
              )
            }
          >
            Remove this Mac
          </Button>
        </div>
      )}
      <p className="license-privacy">{PRIVACY_COPY}</p>
    </section>
  );
}
