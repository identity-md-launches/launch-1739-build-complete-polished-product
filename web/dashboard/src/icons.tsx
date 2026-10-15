import type { CSSProperties } from 'react';
const paths = {
  search: <><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/></>,
  arrow: <><path d="M5 12h14m-5-5 5 5-5 5"/></>,
  external: <><path d="M14 4h6v6m0-6L10 14M10 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5"/></>,
  grid: <><rect x="4" y="4" width="6" height="6" rx="1.5"/><rect x="14" y="4" width="6" height="6" rx="1.5"/><rect x="4" y="14" width="6" height="6" rx="1.5"/><rect x="14" y="14" width="6" height="6" rx="1.5"/></>,
  user: <><circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/></>,
  skills: <><path d="m12 3 2.7 5.4 6 .9-4.4 4.3 1.1 6-5.4-2.8L6.6 20l1.1-6-4.4-4.3 6-.9Z"/></>,
  chart: <><path d="M5 20V10m7 10V4m7 16v-7"/></>,
  code: <><path d="m7 7-5 5 5 5m10-10 5 5-5 5m-3-13-4 20"/></>,
  shield: <><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/></>,
  layout: <><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M9 9v11"/></>,
  book: <><path d="M12 6c-3-3-7-2-9-1v14c3-1 6-1 9 1 3-2 6-2 9-1V5c-2-1-6-2-9 1Zm0 0v14"/></>,
  plus: <path d="M12 5v14M5 12h14"/>,
  check: <path d="m5 12 4 4L19 6"/>,
  close: <path d="m6 6 12 12M6 18 18 6"/>,
  refresh: <><path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 6a8 8 0 0 1 13 2M4.9 16a8 8 0 0 0 13 2"/></>,
  info: <><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7v.1"/></>,
  wallet: <><path d="M20 8V5a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15v12H5a2 2 0 0 1-2-2V6m17 6h-5v4h5"/></>,
  copy: <><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M15 8V4H4v11h4"/></>,
  eye: <><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></>,
} as const;
export type IconName = keyof typeof paths;
export function Icon({ name, size = 20, style }: { name: IconName; size?: number; style?: CSSProperties }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={style}>{paths[name]}</svg>;
}
export function EmptyArt() {
  return <svg className="empty-art" width="128" height="88" viewBox="0 0 128 88" fill="none" aria-hidden="true"><path d="M15 55h98M64 7v73" stroke="#dce3d7" strokeDasharray="3 5"/><rect x="18" y="28" width="35" height="38" rx="12" fill="#e9eee3" transform="rotate(-10 18 28)"/><rect x="82" y="22" width="30" height="34" rx="10" fill="#e9eee3" transform="rotate(12 82 22)"/><rect x="42" y="13" width="46" height="56" rx="15" fill="#f7f9f3" stroke="#a8ba9c"/><circle cx="65" cy="33" r="7" stroke="#58734a" strokeWidth="2"/><path d="M53 56c0-14 24-14 24 0" stroke="#58734a" strokeWidth="2" strokeLinecap="round"/><circle cx="91" cy="67" r="12" fill="#244c3c"/><path d="m86 67 3 3 6-7" stroke="#e0edba" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
