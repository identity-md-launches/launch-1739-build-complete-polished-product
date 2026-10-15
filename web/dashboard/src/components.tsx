import { useEffect, useId, useRef, type ReactNode } from 'react';
import { Icon } from './icons';
export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const closeRef = useRef(onClose); closeRef.current = onClose;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    ref.current?.showModal();
    const bodyOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = bodyOverflow; ref.current?.close(); previous?.focus(); };
  }, []);
  return <dialog ref={ref} className="dialog" aria-labelledby={titleId} onKeyDown={e => {
    if (e.key !== 'Tab') return;
    const controls = [...e.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]')].filter(el => el.getClientRects().length);
    const first = controls[0], last = controls.at(-1);
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
  }} onCancel={e => { e.preventDefault(); closeRef.current(); }} onClick={e => { if (e.target === e.currentTarget) closeRef.current(); }}>
    <div className="dialog-content"><div className="dialog-heading"><h2 id={titleId}>{title}</h2><button className="icon-button" onClick={onClose} aria-label="Close"><Icon name="close"/></button></div>{children}</div>
  </dialog>;
}
export function Notice({ children, error = false }: { children: ReactNode; error?: boolean }) {
  return <div className={`notice ${error ? 'notice-error' : ''}`} role={error ? 'alert' : undefined}><Icon name="info" size={18}/><div>{children}</div></div>;
}
export function Loading({ label = 'Reading Ethereum…' }: { label?: string }) {
  return <div className="loading-state" role="status"><span className="spinner" aria-hidden="true"/><span>{label}</span></div>;
}
export function External({ href, children, className = '' }: { href: string; children: ReactNode; className?: string }) {
  return <a className={`external-link ${className}`} href={href} target="_blank" rel="noopener noreferrer">{children}<Icon name="external" size={14}/><span className="sr-only"> (opens in a new tab)</span></a>;
}
