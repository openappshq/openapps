import ThanksPage from "../../../shared/ThanksPage";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import "../styles.css";

export default function Thanks() {
  return (
    <>
      <MarketingHeader productId="opennotes" links={[]} />
      <ThanksPage app="opennotes" asksPermissions={false} />
      <MarketingFooter productId="opennotes" />
    </>
  );
}
