import { SiteFooter, SiteHeader } from "../home/SiteChrome";
import ThanksPage from "../shared/ThanksPage";
import "../home/styles.css";

/** Site-wide checkout return, used when a cart held more than one app. */
export default function Thanks() {
  return (
    <>
      <SiteHeader />
      <ThanksPage />
      <SiteFooter />
    </>
  );
}
