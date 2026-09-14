import ThanksPage from "../../../shared/ThanksPage";
import { SiteFooter, SiteHeader } from "../SiteChrome";
import "../styles.css";

export default function Thanks() {
  return (
    <>
      <SiteHeader />
      <ThanksPage app="openklack" />
      <SiteFooter />
    </>
  );
}
