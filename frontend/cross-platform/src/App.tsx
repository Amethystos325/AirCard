import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { open, save } from '@tauri-apps/plugin-dialog';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { CreditCard, Smartphone, RefreshCw, ScanLine, Plus, ArrowUpRight, ChevronDown, Check, ImagePlus, X, RotateCcw, Download, LoaderCircle, ShieldCheck, Settings, Radio, Copy, Trash2, Terminal, Maximize2, Minus } from 'lucide-react';
import { useApp, type Card } from './state';
import { demo } from './bridge';
import styles from './App.module.css';

async function exportCard(card: Card, run: ReturnType<typeof useApp>['run'], title: string) {
  if (demo) return;
  const path = await save({ title, defaultPath: 'DittoCard-backup.zip', filters: [{ name: 'ZIP', extensions: ['zip'] }] });
  if (path) await run('card.export', { card: card.card, deviceKey: card.deviceKey, destination: path });
}
const cardKey = (card: Card) => `${card.deviceKey}:${card.card}`;

export default function App() {
  const { state, dispatch, run, t } = useApp();
  const [selected, select] = useState<{ card: Card; path?: string }>();
  const [viewer, view] = useState<Card>();
  const [logs, showLogs] = useState(false);
  const [hidden, hide] = useState<string[]>([]);
  const [dragged, drag] = useState<string>();
  const [reading, readCard] = useState<string>();
  const logEnd = useRef<HTMLDivElement>(null);
  const visible = state.cards.filter(c => c.kind === 'secure-element' && (!state.device || c.deviceKey === state.device.key) && !hidden.includes(cardKey(c)));
  const blocked = state.busy || !state.device?.compatible || state.pending.some(p => p.deviceKey === state.device?.key);
  useEffect(() => { if (logs) logEnd.current?.scrollIntoView?.({ block: 'nearest' }); }, [state.logs, logs]);
  useEffect(() => {
    if (demo || selected) return;
    const listener = getCurrentWebview().onDragDropEvent(e => {
      if (e.payload.type === 'leave') { drag(undefined); return; }
      const { x, y } = e.payload.position;
      const key = document.elementFromPoint(x / window.devicePixelRatio, y / window.devicePixelRatio)?.closest<HTMLElement>('[data-card-key]')?.dataset.cardKey;
      drag(key);
      if (e.payload.type === 'drop') {
        const card = visible.find(c => cardKey(c) === key);
        if (card && e.payload.paths[0] && !state.busy) select({ card, path: e.payload.paths[0] });
        drag(undefined);
      }
    });
    return () => { void listener.then(unlisten => unlisten()); };
  }, [selected, state.busy, state.cards, state.device, hidden]);
  async function read(card: Card) {
    readCard(cardKey(card));
    try { await run('card.read', { device: state.device?.id, card: card.card }); } finally { readCard(undefined); }
  }
  return <div className={styles.app}>
    <header className={styles.header}>
      <div className={styles.brand}><span className={styles.brandIcon}><CreditCard size={23}/></span><div className={styles.brandTitle}><h1>{state.language === 'en' ? 'Ditto Card' : '百变卡片'}</h1><span className={styles.version}>v0.2</span></div></div>
      <div className={styles.device} title={state.device ? `${state.device.product} · iOS ${state.device.version} · ${state.device.build}` : t('offlineHint')} aria-live="polite"><i data-connected={!!state.device}/><div>{state.device ? <><strong>{state.device.name}</strong><p>{state.device.product} · iOS {state.device.version}</p></> : <span>{t('offline')}</span>}</div><button className={styles.iconButton} aria-label={t('refresh')} disabled={state.busy || state.scanning} onClick={() => void run('device')}><RefreshCw size={13}/></button></div>
      <button className={`${styles.scanButton} ${state.scanning ? styles.stopButton : ''}`} disabled={!state.scanning && blocked} onClick={() => void run(state.scanning ? 'scan.stop' : 'scan.start', { device: state.device?.id })}>{state.scanning ? <LoaderCircle className={styles.spin} size={17}/> : <Radio size={17}/>}<span>{t(state.scanning ? 'stopScan' : 'scan')}</span></button>
      <details className={styles.settings}><summary aria-label={t('preferences')} title={t('preferences')}><Settings size={17}/></summary><div className={styles.preferences}><label>{t('language')}<select aria-label={t('language')} value={state.language} onChange={e => dispatch({ type: 'patch', value: { language: e.target.value as 'zh' | 'en' } })}><option value="zh">简体中文</option><option value="en">English</option></select></label><label>{t('settings')}<select aria-label={t('settings')} value={state.theme} onChange={e => dispatch({ type: 'patch', value: { theme: e.target.value } })}>{['system', 'light', 'dark'].map(v => <option key={v} value={v}>{t(v)}</option>)}</select></label></div></details>
    </header>
    {state.scanning && <section className={styles.scanBanner}><Smartphone size={22}/><div><strong>{t('scanTitle')}</strong><p>{t('scanning')}</p></div><button onClick={() => void run('scan.stop')}>{t('done')}</button></section>}
    {state.device && !state.device.compatible && <div className={styles.notice}>{t('noCompatible')}</div>}
    {state.pending.map(p => <section className={styles.recovery} key={p.id}><ShieldCheck/><div><strong>{t('recovery')}</strong><p>{t('recoveryHint')}</p></div><button disabled={state.busy || p.deviceKey !== state.device?.key} onClick={() => void run('recovery.resume', { operationId: p.id })}>{t('recover')}</button>{p.canIsolate && <button disabled={state.busy || p.deviceKey !== state.device?.key} onClick={() => void run('recovery.isolate', { operationId: p.id })}>{t('isolate')}</button>}</section>)}
    {state.unresolved.map(p => <section className={styles.recovery} key={p.id}><ShieldCheck/><div><strong>{t('unresolved')} · {p.card.slice(0, 7)}</strong><p>{t('unresolvedHint')}</p></div><button disabled={state.busy || p.deviceKey !== state.device?.key} onClick={() => void run('recovery.resume', { operationId: p.id })}>{t('recheck')}</button></section>)}
    <main className={styles.main} aria-label={t('cards')}>
      {visible.length ? <div className={styles.grid}>{visible.map((card, index) => <CardTile key={cardKey(card)} card={card} index={index} targeted={dragged === cardKey(card)} reading={reading === cardKey(card)} disabled={blocked || state.scanning || state.device?.key !== card.deviceKey} edit={() => select({ card })} read={() => void read(card)} exportBackup={() => void exportCard(card, run, t('exportDialog'))} view={() => view(card)} remove={() => hide([...hidden, cardKey(card)])}/>)}</div> : <section className={styles.empty}><ScanLine size={58} strokeWidth={1.25}/><h2>{t('empty')}</h2><ol><li>{t('stepScan')}</li><li>{t('stepWallet')}</li><li>{t('stepDetected')}</li></ol>{!state.device && <p>{t('offlineHint')}</p>}<button className={styles.primary} disabled={blocked || state.scanning} onClick={() => void run('scan.start', { device: state.device?.id })}><Radio size={16}/>{t('startScan')}</button></section>}
    </main>
    {state.error && <div role="alert" className={styles.error}>{t(state.error)}<button aria-label={t('close')} onClick={() => dispatch({ type: 'patch', value: { error: undefined } })}><X size={16}/></button></div>}
    {logs && <section className={styles.logs}><div className={styles.logHeading}><strong>{t('logs')}</strong><button onClick={() => dispatch({ type: 'patch', value: { logs: [] } })}>{t('clear')}</button></div><div className={styles.logBody}>{state.logs.map((line, i) => <p key={i}>{t(line)}</p>)}<div ref={logEnd}/></div></section>}
    <footer className={styles.footer}>
      {state.busy && <div className={styles.progress} role="progressbar" aria-label={t(state.stage)}><span/></div>}
      <div className={styles.statusRow}><div className={styles.status} aria-live="polite"><span>{state.busy && <LoaderCircle className={styles.spin} size={13}/>} {t(state.stage)}</span><small>{visible.length} {t('cards')}{demo && ` · ${t('demo')}`}</small></div><div className={styles.footerActions}>{hidden.length > 0 && <button onClick={() => hide([])}>{t('showRemoved')}</button>}{state.busy && <button onClick={() => void run('cancel')}>{t('cancel')}</button>}<button onClick={() => showLogs(!logs)} aria-expanded={logs}><Terminal size={14}/>{t('logs')}<ChevronDown size={11} style={{ transform: logs ? undefined : 'rotate(180deg)' }}/></button></div></div>
    </footer>
    {selected && <Details card={state.cards.find(c => cardKey(c) === cardKey(selected.card)) || selected.card} initialPath={selected.path} close={() => select(undefined)}/>}
    {viewer?.preview && <ArtworkViewer card={viewer} close={() => view(undefined)}/>}
  </div>;
}

function CardTile({ card, index, targeted, reading, disabled, edit, read, exportBackup, view, remove }: { card: Card; index: number; targeted: boolean; reading: boolean; disabled: boolean; edit: () => void; read: () => void; exportBackup: () => void; view: () => void; remove: () => void }) {
  const { state, t } = useApp();
  const [pointer, point] = useState({ x: 0, y: 0 });
  const [copied, copy] = useState(false);
  useEffect(() => { if (copied) { const id = setTimeout(() => copy(false), 1800); return () => clearTimeout(id); } }, [copied]);
  return <article className={styles.cardTile} data-card-key={cardKey(card)}>
    <button className={styles.cardFace} data-art={!!card.preview} data-targeted={targeted} aria-label={`${card.preview ? t('viewLarge') : t('select')} ${card.label || index + 1}`} onClick={card.preview ? view : edit} onPointerMove={e => { const rect = e.currentTarget.getBoundingClientRect(); point({ x: (e.clientX - rect.left) / rect.width - .5, y: (e.clientY - rect.top) / rect.height - .5 }); }} onPointerLeave={() => point({ x: 0, y: 0 })} style={{ '--tilt-x': `${-pointer.y * 9}deg`, '--tilt-y': `${pointer.x * 9}deg`, '--shadow-x': `${pointer.x * 10}px` } as CSSProperties}>
      {card.preview ? <img src={card.preview} alt={card.label || t('card')}/> : <div className={styles.placeholder}><div className={styles.cardSymbols}><Radio size={15}/><CreditCard size={16}/></div><CreditCard size={32} strokeWidth={1.2}/><strong>{targeted ? t('releaseImage') : t('unassigned')}</strong><small>{t('dropHint')}</small></div>}
      {reading && <span className={styles.scanOverlay}><span><Radio size={14}/>{t('reading')}</span></span>}
    </button>
    <div className={styles.cardCaption}><strong title={card.label}>{card.label || `${t('card')} #${index + 1}`}</strong><button className={styles.hash} title={t('copyId')} aria-label={t('copyId')} onClick={() => void navigator.clipboard.writeText(card.card).then(() => copy(true)).catch(() => copy(false))}><span>{card.card.slice(0, 8)}…{card.card.slice(-6)}</span>{copied ? <Check size={10}/> : <Copy size={10}/>}</button><button className={styles.iconButton} title={t('removeCard')} aria-label={`${t('removeCard')} ${card.label}`} disabled={state.busy} onClick={remove}><Trash2 size={13}/></button></div>
    <div className={styles.cardActions}><button disabled={state.busy} onClick={edit}><ImagePlus size={14}/>{t('changeArtwork')}</button><button className={styles.primary} disabled={disabled} onClick={read}>{reading ? <LoaderCircle className={styles.spin} size={14}/> : <Download size={14}/>} {t(reading ? 'reading' : 'read')}</button><button aria-label={`${t('export')} ${card.label}`} title={t('export')} disabled={!card.backup || state.busy} onClick={exportBackup}><ArrowUpRight size={15}/></button></div>
  </article>;
}

function ArtworkViewer({ card, close }: { card: Card; close: () => void }) {
  const { t } = useApp(); const dialog = useRef<HTMLDialogElement>(null); const canvas = useRef<HTMLDivElement>(null);
  const [zoom, setZoom] = useState(1); const [ratio, setRatio] = useState(1536 / 969);
  const [bounds, setBounds] = useState({ width: 800, height: 450 });
  useEffect(() => {
    dialog.current?.showModal();
    const element = canvas.current!;
    const measure = () => { if (element.clientWidth && element.clientHeight) setBounds({ width: element.clientWidth, height: element.clientHeight }); };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(measure); observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const imageWidth = Math.min(bounds.width, bounds.height * ratio) * zoom;
  const imageHeight = imageWidth / ratio;
  return <dialog ref={dialog} className={`${styles.dialog} ${styles.viewer}`} onCancel={e => { e.preventDefault(); close(); }}><div className={styles.dialogHeading}><h2>{card.label || t('card')}</h2><button className={styles.iconButton} aria-label={t('close')} onClick={close}><X size={19}/></button></div><div ref={canvas} className={styles.viewerCanvas}><div style={{ width: Math.max(bounds.width, imageWidth), height: Math.max(bounds.height, imageHeight) }}><img src={card.preview} alt={card.label} style={{ width: imageWidth, height: imageHeight }} onLoad={e => { const img = e.currentTarget; if (img.naturalHeight) setRatio(img.naturalWidth / img.naturalHeight); }}/></div></div><div className={styles.viewerTools}><button aria-label={t('zoomOut')} disabled={zoom <= 1} onClick={() => setZoom(Math.max(1, zoom - .25))}><Minus size={15}/></button><input aria-label={t('zoom')} type="range" min="1" max="4" step=".25" value={zoom} onChange={e => setZoom(Number(e.target.value))}/><button aria-label={t('zoomIn')} disabled={zoom >= 4} onClick={() => setZoom(Math.min(4, zoom + .25))}><Plus size={15}/></button><span>{Math.round(zoom * 100)}%</span><button onClick={() => setZoom(1)}><Maximize2 size={14}/>{t('fit')}</button></div></dialog>;
}

function Details({ card, initialPath, close }: { card: Card; initialPath?: string; close: () => void }) {
  const { state, run, t } = useApp(); const dialog = useRef<HTMLDialogElement>(null);
  const [source, setSource] = useState(''); const [raw, setRaw] = useState(''); const [ratio, setRatio] = useState(1536 / 969);
  const [zoom, setZoom] = useState(1); const [x, setX] = useState(.5); const [y, setY] = useState(.5);
  const [prepared, setPrepared] = useState<{ imageId: string; preview: string }>(); const [preparing, setPreparing] = useState(false);
  const deviceReady = state.device?.key === card.deviceKey && state.device?.compatible;
  const disabled = state.busy || state.scanning || !deviceReady || state.pending.some(p => p.deviceKey === card.deviceKey);
  const width = Math.min(1, (1536 / 969) / ratio) / zoom, height = Math.min(1, ratio / (1536 / 969)) / zoom;
  const crop = { x: (1 - width) * x, y: (1 - height) * y, width, height };
  async function load(path: string) {
    setPreparing(true);
    try { const value = await run('image.inspect', { path }); if (value) { setRaw(value.preview); setRatio(value.width / value.height); setSource(path); setZoom(1); setX(.5); setY(.5); setPrepared(undefined); } } finally { setPreparing(false); }
  }
  useEffect(() => { dialog.current?.showModal(); if (initialPath) void load(initialPath); }, []);
  useEffect(() => {
    if (demo) return;
    const listener = getCurrentWebview().onDragDropEvent(e => { if (e.payload.type === 'drop' && e.payload.paths[0] && !state.busy) void load(e.payload.paths[0]); });
    return () => { void listener.then(unlisten => unlisten()); };
  }, [state.busy]);
  async function choose() { if (demo) return; const path = await open({ title: t('fileDialog'), multiple: false, filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp'] }] }); if (path) await load(path); }
  async function generate() { setPreparing(true); try { const result = await run('image.prepare', { path: source, crop }); if (result) setPrepared(result); } finally { setPreparing(false); } }
  async function exportBackup() { if (demo) return; const path = await save({ title: t('exportDialog'), defaultPath: 'DittoCard-backup.zip', filters: [{ name: 'ZIP', extensions: ['zip'] }] }); if (path) await run('card.export', { card: card.card, deviceKey: card.deviceKey, destination: path }); }
  return <dialog className={styles.dialog} ref={dialog} onCancel={e => { e.preventDefault(); close(); }}>
    <div className={styles.dialogHeading}><div><small>WALLET / {t('card')}</small><h2>{card.label || t('card')}</h2></div><button aria-label={t('close')} className={styles.iconButton} onClick={close}><X size={21}/></button></div>
    <div className={styles.previews}><section><h3>{t('original')}</h3><div className={styles.preview}>{card.preview ? <img src={card.preview} alt={t('original')}/> : <span><CreditCard/><small>{t('noArtwork')}</small></span>}</div><button disabled={disabled} onClick={() => void run('card.read', { device: state.device?.id, card: card.card })}><RefreshCw size={14}/>{t('read')}</button></section><section><h3>{t('replacement')}</h3><button className={styles.preview} disabled={state.busy || preparing} onClick={() => void choose()} aria-label={t('choose')}>{prepared ? <img src={prepared.preview} alt={t('replacement')}/> : raw ? <img src={raw} alt={t('replacement')} style={{ position: 'absolute', maxWidth: 'none', width: `${100 / width}%`, height: `${100 / height}%`, left: `${-crop.x / width * 100}%`, top: `${-crop.y / height * 100}%` }}/> : <span><ImagePlus/><small>{t('drop')}</small></span>}</button><button disabled={state.busy || preparing} onClick={() => void choose()}><Plus size={14}/>{t('choose')}</button></section></div>
    {source && <div className={styles.crop}>{([{ key: 'zoom', value: zoom, min: 1, max: 3, set: setZoom }, { key: 'horizontal', value: x, min: 0, max: 1, set: setX }, { key: 'vertical', value: y, min: 0, max: 1, set: setY }]).map(item => <label key={item.key}>{t(item.key)}<input type="range" min={item.min} max={item.max} step="0.01" value={item.value} disabled={state.busy || preparing} onChange={e => { item.set(Number(e.target.value)); setPrepared(undefined); }}/></label>)}<button disabled={state.busy || preparing} onClick={() => void generate()}>{preparing && <LoaderCircle className={styles.spin} size={15}/>} {t(prepared ? 'prepared' : 'preview')}</button></div>}
    <p className={styles.detailNote}><ShieldCheck size={16}/>{t('firstBackup')}</p>
    {state.busy && <p className={styles.detailNote} role="status"><LoaderCircle className={styles.spin} size={16}/>{t(state.stage)}</p>}
    {state.error && <p className={styles.error} role="alert">{t(state.error)}</p>}
    <div className={styles.dialogActions}><button disabled={!card.backup || state.busy} onClick={() => void exportBackup()}><Download size={16}/>{t('export')}</button><button title={t('restoreNote')} disabled={!card.backup || disabled} onClick={() => void run('card.restore', { device: state.device?.id, card: card.card })}><RotateCcw size={16}/>{t('restore')}</button><button className={styles.primary} disabled={!prepared || disabled || preparing} onClick={() => void run('card.apply', { device: state.device?.id, card: card.card, imageId: prepared?.imageId })}>{t('apply')}<ArrowUpRight size={16}/></button></div>
  </dialog>;
}
