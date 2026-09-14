import { MarketingHeader, MarketingFooter } from "../shared/MarketingChrome";
import ThanksPage from "../shared/ThanksPage";
import "../home/styles.css";

/** Site-wide checkout return, used when a cart held more than one app. */
export default function Thanks() {
  return (
    <>
      <MarketingHeader links={[{ label: "The apps", href: "/#apps" }]} />
      <ThanksPage />
      <MarketingFooter />
    </>
  );
}
