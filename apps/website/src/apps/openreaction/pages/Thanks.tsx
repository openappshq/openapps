import ThanksPage from "../../../shared/ThanksPage";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import "../styles.css";

export default function Thanks({ kind = "paid" }: { kind?: "paid" | "trial" }) {
  return (
    <>
      <MarketingHeader productId="openreaction" links={[]} />
      <ThanksPage app="openreaction" kind={kind} />
      <MarketingFooter productId="openreaction" />
    </>
  );
}
