import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Button, Input, Label, TextField } from "@heroui/react";
import { BadgeCheck, KeyRound, WifiOff } from "lucide-react";

export type LicenseView = {
  revision: number;
  ready: boolean;
  environment: "test" | "live";
  state: "unlicensed" | "trial" | "trialEnded" | "licensed" | "grace" | "checkRequired" | "revoked";
  daysLeft?: number;
  daysOffline?: number;
  coreFeature: boolean;
  clockChanged: boolean;
  trialUsed: boolean;
  graceWarning: boolean;
  checking: boolean;
  lastSuccessAt: number | null;
  lastError: string | null;
  pendingKey: string | null;
  pendingTrial: boolean;
  buyUrl: string;
  trialUrl: string;
  supportUrl: string;
};

export const PRIVACY_COPY =
  "Official builds check your license with Dodo Payments, our payment provider. The license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, what you type, and how you use the app are never sent. Builds from source never contact the license service.";

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
  const [expectTrial, setExpectTrial] = useState(false);
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
  // The trial thanks page marks its key, so a second trial is refused without calling Dodo.
  const trialKey = expectTrial || (!!pendingKey && key === pendingKey && !!view?.pendingTrial);

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
  const canEnterKey = view && ["unlicensed", "trial", "trialEnded", "revoked"].includes(view.state);
  const buy = (
    <Button
      variant="primary"
      isDisabled={busy}
      onPress={() => void run(() => invoke("open_license_link", { link: "buy" }))}
    >
      Buy for $5
    </Button>
  );

  // Every state that keeps a record can give the slot back, except while a check is required.
  const remove = (
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
  );

  if (!view || !view.ready)
    return (
      <section className="license" aria-label="License">
        <h2>License</h2>
        <p role="status">Loading license…</p>
      </section>
    );

  const status: Record<LicenseView["state"], string> = {
    unlicensed: "Not licensed on this Mac.",
    trial: `Trial: about ${view.daysLeft ?? 0} ${view.daysLeft === 1 ? "day" : "days"} left`,
    trialEnded: view.clockChanged
      ? "Clock changed — connect to the internet to verify your trial."
      : "Your trial has ended.",
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
  const offline = view.state === "checkRequired" || (view.state === "grace" && view.graceWarning);

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
        <p data-warning={offline || view.state === "revoked" || view.state === "trialEnded"}>
          {status[view.state]}
        </p>
      </div>
      {view.state === "checkRequired" && view.lastError && (
        <p className="inline-error" role="alert">
          {view.lastError}
        </p>
      )}
      {notice && (
        <p className="feedback" role="status">
          {notice}
        </p>
      )}
      {(view.state === "unlicensed" || view.state === "trialEnded" || view.state === "trial") && (
        <div className="actions">
          {view.state === "unlicensed" && !view.trialUsed && (
            <Button
              variant="secondary"
              isDisabled={busy}
              onPress={() =>
                void run(async () => {
                  const next = await invoke<LicenseView>("start_license_trial");
                  setExpectTrial(true);
                  return next;
                })
              }
            >
              Start 3-day trial
            </Button>
          )}
          {buy}
        </div>
      )}
      {view.state === "unlicensed" && view.trialUsed && (
        <p className="inline-hint">The trial was already used on this Mac.</p>
      )}
      {view.state === "unlicensed" && expectTrial && (
        <p className="inline-hint">Paste the trial key from your email below.</p>
      )}
      {view.state === "revoked" && (
        <div className="actions">
          {buy}
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
            void run(
              async () => {
                const next = await invoke<LicenseView>("activate_license", {
                  key,
                  expectTrial: trialKey && view.state === "unlicensed",
                });
                setTyped(null);
                setExpectTrial(false);
                return next;
              },
              (next) => (next.state === "trial" ? "Trial started." : "This Mac is licensed."),
            );
          }}
        >
          <TextField
            className="license-field"
            value={key}
            onChange={setTyped}
            isDisabled={busy}
            autoComplete="off"
          >
            <Label>
              {view.state === "trial" ? "Paste a paid key to keep your settings" : "License key"}
            </Label>
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
      {(view.state === "licensed" || view.state === "grace") && (
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
          {remove}
        </div>
      )}
      {(view.state === "trial" || view.state === "trialEnded" || view.state === "revoked") && (
        <div className="actions">
          {view.state === "trialEnded" && view.clockChanged && (
            <Button
              variant="secondary"
              isDisabled={busy}
              onPress={() =>
                void run(() => invoke<LicenseView>("check_license_now"), "Trial verified.")
              }
            >
              {view.checking ? "Checking…" : "Try again"}
            </Button>
          )}
          {remove}
        </div>
      )}
      {view.state === "checkRequired" && (
        <div className="actions">
          <Button
            variant="secondary"
            isDisabled={busy}
            onPress={() =>
              void run(() => invoke<LicenseView>("check_license_now"), "License verified.")
            }
          >
            {view.checking ? "Checking…" : "Try again"}
          </Button>
        </div>
      )}
      <p className="license-privacy">{PRIVACY_COPY}</p>
    </section>
  );
}
