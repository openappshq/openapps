import ThanksPage from "../../../shared/ThanksPage";
import { MarketingHeader, MarketingFooter } from "../../../shared/MarketingChrome";
import "../styles.css";

export default function Thanks() {
  return (
    <>
      <MarketingHeader productId="hertz" links={[]} />
      <ThanksPage app="hertz" asksPermissions={false} />
      <MarketingFooter productId="hertz" />
    </>
  );
}
