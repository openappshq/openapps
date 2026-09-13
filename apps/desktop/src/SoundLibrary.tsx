import { motion } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { useState } from "react";
import { Button } from "@heroui/react";
import { Check, Download, Play, Search, Square, Upload } from "lucide-react";
import { packLabel, type Desktop, type Pack, type Preset } from "./useDesktop";

const core = ["novelkeys-cream", "cherry-mx-blue-pbt", "drop-holy-panda", "ibm-buckling-spring"];

export function SoundLibrary({ desktop, preset }: { desktop: Desktop; preset: Preset }) {
  const { packs, busy, preview, audition, changePreset } = desktop;
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState("Curated");
  const [details, setDetails] = useState<Pack | null>(null);
  const filtered = packs.filter(
    (p) =>
      (search || filter !== "Curated" || core.includes(p.originalId)) &&
      (filter === "Curated" || filter === "All sounds" || p.kind === filter) &&
      `${packLabel(p)} ${p.kind} ${p.description}`
        .toLowerCase()
        .includes(search.trim().toLowerCase()),
  );
  return (
    <section className="sound-library" aria-labelledby="library-heading">
      <div className="section-heading">
        <div>
          <h2 id="library-heading">Find your sound</h2>
          <p>A few favorites to start. Plenty more to discover.</p>
        </div>
        <Button variant="secondary" onPress={() => void desktop.importSounds()} isDisabled={busy}>
          <Upload size={15} />
          Import sounds
        </Button>
      </div>
      <div className="library-toolbar">
        <div className="filter-group" aria-label="Filter sounds">
          {["Curated", "All sounds", "Linear", "Tactile", "Clicky"].map((kind) => (
            <Button
              key={kind}
              variant="ghost"
              aria-pressed={filter === kind}
              onPress={() => setFilter(kind)}
            >
              {kind}
            </Button>
          ))}
        </div>
        <label className="sound-search">
          <Search size={15} />
          <span className="sr-only">Search sounds</span>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search sounds"
            autoCorrect="off"
            spellCheck={false}
          />
        </label>
      </div>
      <div className="sound-grid">
        {filtered.map((pack) => (
          <motion.article
            layout="position"
            {...enter}
            whileHover={{ y: -2 }}
            className={`sound-card ${pack.id === preset.packId ? "selected" : ""}`}
            key={pack.id}
          >
            <div className="sound-card-top">
              <div
                className="mini-key"
                style={{ "--key-color": pack.color } as React.CSSProperties}
                aria-hidden="true"
              >
                <span>+</span>
              </div>
              <Button
                isIconOnly
                variant="ghost"
                aria-label={`${preview === pack.id ? "Stop preview of" : "Preview"} ${packLabel(pack)}`}
                isDisabled={busy}
                onPress={() => void audition(pack.id)}
              >
                {preview === pack.id ? <Square size={16} /> : <Play size={16} />}
              </Button>
            </div>
            <span className="pack-brand">{pack.brand}</span>
            <h3>{pack.name}</h3>
            <p>{pack.description}</p>
            <div className="sound-card-bottom">
              <Button
                variant="ghost"
                className="pack-info"
                onPress={() => setDetails(details?.id === pack.id ? null : pack)}
                aria-expanded={details?.id === pack.id}
              >
                Details
              </Button>
              <Button
                variant="secondary"
                isDisabled={busy || pack.id === preset.packId}
                onPress={() => void changePreset(preset.id, { packId: pack.id })}
              >
                {pack.id === preset.packId ? (
                  <>
                    <Check size={14} />
                    Applied
                  </>
                ) : (
                  "Apply"
                )}
              </Button>
            </div>
          </motion.article>
        ))}
      </div>
      {filtered.length === 0 && (
        <div className="empty-state">
          <h3>No sounds match your filters</h3>
          <p>Try another name or explore the full library.</p>
          <Button
            variant="secondary"
            onPress={() => {
              setSearch("");
              setFilter("All sounds");
            }}
          >
            Show all sounds
          </Button>
        </div>
      )}
      {details && (
        <motion.aside
          {...enter}
          className="pack-details"
          aria-label={`Details for ${packLabel(details)}`}
        >
          <div className="section-heading">
            <h3>{packLabel(details)}</h3>
            <Button variant="ghost" onPress={() => setDetails(null)}>
              Close details
            </Button>
          </div>
          <p>
            {details.kind} ·{" "}
            {details.supportsKeyUp
              ? "Recorded press and release"
              : "Recorded press; silent release"}{" "}
            · By {details.author}
          </p>
          <p>
            Installed version <code>{details.version.slice(0, 12)}</code>. Presets keep this version
            until you apply another.
          </p>
          <details>
            <summary>Recording credits and licenses</summary>
            <pre>{details.credits}</pre>
          </details>
        </motion.aside>
      )}
      <div className="library-foot">
        <span>{packs.length} installed pack versions · Works offline</span>
        <Button variant="ghost" isDisabled={busy} onPress={() => void desktop.checkPackUpdates()}>
          <Download size={14} />
          Add bundled updates
        </Button>
      </div>
    </section>
  );
}
