import { Download, Terminal } from "lucide-react";
import { installLabel, licensingFor } from "./licensing";

/** The header's call to action: to the install page, worded for what it offers. */
export function installAction(app: string) {
  const licensing = licensingFor(app);
  return {
    label: installLabel(licensing),
    href: licensing.downloadPageUrl,
    icon: licensing.downloadUrl ? <Download size={16} /> : <Terminal size={16} />,
  };
}
