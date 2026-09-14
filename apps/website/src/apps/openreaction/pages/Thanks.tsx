import ThanksPage from "../../../shared/ThanksPage";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import "../styles.css";

export default function Thanks() {
  return (
    <>
      <MarketingHeader productId="openreaction" links={[]} />
      <ThanksPage app="openreaction" />
      <MarketingFooter productId="openreaction" />
    </>
  );
}
