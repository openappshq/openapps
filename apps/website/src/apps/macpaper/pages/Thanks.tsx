import ThanksPage from "../../../shared/ThanksPage";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import "../styles.css";

export default function Thanks() {
  return (
    <>
      <MarketingHeader productId="macpaper" links={[]} />
      <ThanksPage app="macpaper" asksPermissions={false} />
      <MarketingFooter productId="macpaper" />
    </>
  );
}
