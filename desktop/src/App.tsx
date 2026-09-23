import { useEffect, useRef, useState } from 'react';
import { open, save } from '@tauri-apps/plugin-dialog';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { CreditCard, Smartphone, RefreshCw, ScanLine, Plus, ArrowUpRight, ChevronDown, Check, ImagePlus, X, RotateCcw, Download, LoaderCircle, ShieldCheck, Layers } from 'lucide-react';
import { useApp, type Card } from './state';
import { demo } from './bridge';
import styles from './App.module.css';

export default function App() {
  const { state, dispatch, run, t } = useApp();
  const [selected, select] = useState<Card>(); const [logs, showLogs] = useState(false);
  const visible = state.cards.filter(c => c.kind === 'secure-element' && (!state.device || c.deviceKey === state.device.key));
  const blocked = state.busy || !state.device?.compatible || state.pending.some(p => p.deviceKey === state.device?.key);
  return <div className={styles.app}>
    <header className={styles.header}>
      <div className={styles.brand}><span className={styles.brandIcon}><Layers size={23}/></span><div><h1>AirCard<span>DESKTOP</span></h1><p>{t('subtitle')}</p></div></div>
      <div className={styles.preferences}><select aria-label={t('language')} value={state.language} onChange={e => dispatch({ type: 'patch', value: { language: e.target.value as 'zh' | 'en' } })}><option value="zh">简体中文</option><option value="en">English</option></select><select aria-label={t('settings')} value={state.theme} onChange={e => dispatch({ type: 'patch', value: { theme: e.target.value } })}>{['system', 'light', 'dark'].map(v => <option key={v} value={v}>{t(v)}</option>)}</select></div>
    </header>
    <section className={styles.device} aria-live="polite"><span className={styles.deviceIcon}><Smartphone size={23}/></span><div><strong>{state.device?.name || t('offline')}</strong><p>{state.device ? `${state.device.product} · iOS ${state.device.version} · ${state.device.build}` : t('offlineHint')}</p></div><span className={styles.connection}><i data-connected={!!state.device}/>{state.device ? t('connected') : 'USB'}</span><button className={styles.iconButton} aria-label={t('refresh')} disabled={state.busy || state.scanning} onClick={() => void run('device')}><RefreshCw size={17}/></button></section>
    {state.device && !state.device.compatible && <div className={styles.notice}>{t('noCompatible')}</div>}
    {state.pending.map(p => <section className={styles.recovery} key={p.id}><ShieldCheck/><div><strong>{t('recovery')}</strong><p>{t('recoveryHint')}</p></div><button disabled={state.busy || p.deviceKey !== state.device?.key} onClick={() => void run('recovery.resume', { operationId: p.id })}>{t('recover')}</button></section>)}
    <main className={styles.main}>
      <div className={styles.sectionHeading}><div><h2>{t('cards')} <span>{visible.length.toString().padStart(2, '0')}</span></h2><p>{state.scanning ? t('scanning') : t('chooseHint')}</p></div><button className={styles.primary} disabled={!state.scanning && blocked} onClick={() => void run(state.scanning ? 'scan.stop' : 'scan.start', { device: state.device?.id })}><ScanLine size={17}/>{t(state.scanning ? 'stopScan' : 'scan')}</button></div>
      {visible.length ? <div className={styles.grid}>{visible.map((card, index) => <button className={styles.cardTile} key={card.deviceKey + card.card} onClick={() => select(card)} aria-label={`${t('select')} ${card.label || index + 1}`}><div className={styles.cardFace}>{card.preview ? <img src={card.preview} alt={card.label || t('card')}/> : <><CreditCard size={30}/><span>{card.label || t('card')}</span><small>WALLET</small></>}</div><div className={styles.cardCaption}><div><strong>{card.label || `${t('card')} ${index + 1}`}</strong><span>{card.backup ? <><ShieldCheck size={12}/>{t('firstBackup')}</> : t('noArtwork')}</span></div><ArrowUpRight size={18}/></div></button>)}</div> : <section className={styles.empty}><div className={styles.cardStack} aria-hidden="true"><div/><div/><div><span>AirCard</span><CreditCard size={27}/><small>MAKE IT YOURS</small></div></div><h2>{t('empty')}</h2><p>{t('emptyHint')}</p><button disabled={blocked} onClick={() => void run('scan.start', { device: state.device?.id })}><Plus size={17}/>{t('scan')}</button></section>}
    </main>
    {state.error && <div role="alert" className={styles.error}>{t(state.error)}<button aria-label={t('close')} onClick={() => dispatch({ type: 'patch', value: { error: undefined } })}><X size={16}/></button></div>}
    {logs && <ol className={styles.logs}>{state.logs.map((line, i) => <li key={i}>{t(line)}</li>)}</ol>}
    <footer className={styles.footer}><div aria-live="polite">{state.busy ? <LoaderCircle className={styles.spin} size={16}/> : <Check size={16}/>}<span>{t(state.stage)}</span></div><div>{demo && <small>{t('demo')}</small>}{state.busy && <button onClick={() => void run('cancel')}>{t('cancel')}</button>}<button onClick={() => showLogs(!logs)} aria-expanded={logs}>{t('logs')}<ChevronDown size={14}/></button></div></footer>
    {selected && <Details card={state.cards.find(c => c.card === selected.card && c.deviceKey === selected.deviceKey) || selected} close={() => select(undefined)}/>}
  </div>;
}

function Details({ card, close }: { card: Card; close: () => void }) {
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
  useEffect(() => { dialog.current?.showModal(); }, []);
  useEffect(() => {
    if (demo) return;
    const listener = getCurrentWebview().onDragDropEvent(e => { if (e.payload.type === 'drop' && e.payload.paths[0] && !state.busy) void load(e.payload.paths[0]); });
    return () => { void listener.then(unlisten => unlisten()); };
  }, [state.busy]);
  async function choose() { if (demo) return; const path = await open({ title: t('fileDialog'), multiple: false, filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp'] }] }); if (path) await load(path); }
  async function generate() { setPreparing(true); try { const result = await run('image.prepare', { path: source, crop }); if (result) setPrepared(result); } finally { setPreparing(false); } }
  async function exportBackup() { if (demo) return; const path = await save({ title: t('exportDialog'), defaultPath: 'AirCard-backup.zip', filters: [{ name: 'ZIP', extensions: ['zip'] }] }); if (path) await run('card.export', { card: card.card, deviceKey: card.deviceKey, destination: path }); }
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
