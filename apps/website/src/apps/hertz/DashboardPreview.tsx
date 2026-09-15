import type { ReactNode } from "react";

/**
 * The dashboard as it looks in the menu bar, drawn in HTML so the page can
 * show it without a screenshot. Sample readings from a quiet afternoon on an
 * M4; the layout, type and cards match the app.
 */

const cpuHistory = [9, 11, 8, 14, 12, 19, 33, 27, 16, 12, 10, 13, 22, 41, 38, 24, 15, 12, 11, 15, 14, 12];
const memoryHistory = [58, 58, 59, 61, 62, 62, 63, 66, 66, 65, 64, 64, 65, 67, 66, 66, 66, 65, 66, 66, 66, 66];
const cores = [22, 18, 30, 12, 8, 6, 5, 4, 3, 5];
const processes: [string, string, string, string?][] = [
  ["Xcode", "48.2", "2.4 GB", "12"],
  ["Safari", "9.6", "1.8 GB", "9"],
  ["Slack", "3.1", "640 MB", "4"],
  ["Terminal", "0.8", "96 MB"],
  ["Hertz", "0.4", "31 MB"],
];

function Sparkline({ values, ceiling, id }: { values: number[]; ceiling: number; id: string }) {
  const w = 100;
  const h = 30;
  const points = values.map((value, index) => [
    (w * index) / (values.length - 1),
    h * (1 - Math.min(value / ceiling, 1)),
  ]);
  const line = points.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  return (
    <svg className="hz-spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <defs>
        <linearGradient id={id} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor="currentColor" stopOpacity="0.22" />
          <stop offset="1" stopColor="currentColor" stopOpacity="0" />
        </linearGradient>
      </defs>
      <polygon points={`0,${h} ${line} ${w},${h}`} fill={`url(#${id})`} />
      <polyline points={line} fill="none" stroke="currentColor" strokeWidth="1.5" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
    </svg>
  );
}

function Card({ label, value, children, className = "" }: { label: string; value?: ReactNode; children?: ReactNode; className?: string }) {
  return (
    <div className={`hz-card ${className}`}>
      <div className="hz-card-head">
        <span className="hz-label">{label}</span>
        {value && <span className="hz-readout">{value}</span>}
      </div>
      {children}
    </div>
  );
}

export default function DashboardPreview() {
  return (
    <div className="hz-window" role="img" aria-label="The Hertz dashboard: health 96 Excellent on an Apple M4, CPU 14.9% with a sparkline and per-core bars, memory 66% used, disk 412 GB free, network 2.4 MB/s down, battery 100%, and the top processes by CPU">
      <div className="hz-menubar" aria-hidden="true">
        <span className="hz-menubar-item hz-menubar-hertz">
          <svg width="14" height="14" viewBox="0 0 128 128" fill="none">
            <path d="M16 66H38L50 36L64 94L78 44L88 66H112" stroke="currentColor" strokeWidth="14" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          15%
        </span>
        <span className="hz-menubar-item">Tue 15:04</span>
      </div>
      <div className="hz-stack" aria-hidden="true">
        <div className="hz-card hz-health">
          <div className="hz-health-row">
            <span className="hz-score">96</span>
            <span className="hz-score-word">Excellent</span>
            <span className="hz-dot" />
            <span className="hz-label hz-uptime">up 1d 4h</span>
          </div>
          <div className="hz-detail">Apple M4 · 4P + 6E · 16 GB · macOS 26.5</div>
        </div>
        <Card label="Diagnosis">
          <div className="hz-insight">
            <span className="hz-insight-icon">✓</span>
            <div>
              <strong>System looks balanced</strong>
              <span>No pressure signal is elevated; top processes are the best next place to inspect.</span>
            </div>
          </div>
        </Card>
        <Card label="CPU" value="14.9%">
          <div className="hz-spark-box">
            <Sparkline values={cpuHistory} ceiling={60} id="hz-cpu-fill" />
          </div>
          <div className="hz-cores">
            {cores.map((core, index) => (
              <span key={index} style={{ height: `${Math.max(2, (18 * core) / 100)}px` }} />
            ))}
          </div>
          <div className="hz-detail">load 1.42 · 1.61 · 1.55   41°C</div>
        </Card>
        <Card label="Memory" value="66%">
          <div className="hz-spark-box hz-spark-memory">
            <Sparkline values={memoryHistory} ceiling={100} id="hz-mem-fill" />
          </div>
          <div className="hz-stats">
            <span><b>10.6 GB</b>used</span>
            <span><b>5.4 GB</b>free</span>
            <span><b>0 KB</b>swap</span>
          </div>
        </Card>
        <div className="hz-pair">
          <Card label="Disk" value={<span className="hz-ring" />}>
            <div className="hz-big">412 GB free</div>
            <div className="hz-bar"><span style={{ width: "58%" }} /></div>
            <div className="hz-stats">
              <span><b>↓ 0 KB/s</b>read, all disks</span>
              <span><b>↑ 1.2 MB/s</b>write, all disks</span>
            </div>
          </Card>
          <Card label="Network">
            <div className="hz-spark-box hz-spark-net">
              <Sparkline values={[2, 4, 3, 9, 14, 8, 5, 6, 12, 22, 18, 9, 4, 3, 5, 8, 6, 4, 3, 4, 6, 5]} ceiling={28} id="hz-net-fill" />
            </div>
            <div className="hz-stats">
              <span><b>↓ 2.4 MB/s</b>down</span>
              <span><b>↑ 180 KB/s</b>up</span>
            </div>
            <div className="hz-detail">en0 · Studio · 10.0.1.24</div>
          </Card>
        </div>
        <Card label="Battery" value="100%">
          <div className="hz-bar"><span style={{ width: "100%" }} /></div>
          <div className="hz-body">charged · 3h 12m on power</div>
        </Card>
        <Card label="Processes" value={<span className="hz-columns"><b>⌄CPU</b><span>MEM</span></span>}>
          <ul className="hz-processes">
            {processes.map(([name, cpu, memory, count]) => (
              <li key={name}>
                <span className="hz-proc-icon" />
                <span className="hz-proc-name">
                  {name}
                  {count && <span className="hz-count">{count}</span>}
                </span>
                <span className="hz-proc-cpu">{cpu}</span>
                <span className="hz-proc-mem">{memory}</span>
              </li>
            ))}
          </ul>
        </Card>
      </div>
      <div className="hz-footer" aria-hidden="true">
        <span className="hz-label">Hertz 0.2.0</span>
        <span className="hz-footer-links">
          <span>Settings…</span>
          <span>Quit</span>
        </span>
      </div>
    </div>
  );
}
