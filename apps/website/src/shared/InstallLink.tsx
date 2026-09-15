import { Link } from "@heroui/react";
import { Download, Terminal } from "lucide-react";
import { installLabel, licensingFor } from "./licensing";

/** A closing-section button to the install page, worded for what it offers. */
export default function InstallLink({ app, className }: { app: string; className: string }) {
  const licensing = licensingFor(app);
  return (
    <Link className={className} href={licensing.downloadPageUrl}>
      {installLabel(licensing)}{" "}
      {licensing.downloadUrl ? <Download size={20} /> : <Terminal size={20} />}
    </Link>
  );
}
