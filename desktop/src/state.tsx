import { createContext, useContext, useEffect, useReducer, type ReactNode } from 'react';
import { request, subscribe } from './bridge';
import { en, zh, type Key } from './i18n';
export type Card = { card: string; deviceKey: string; label: string; kind: string; preview?: string; backup: boolean };
export type Device = { id: string; key: string; name: string; product: string; version: string; build: string; compatible: boolean };
export type State = { cards: Card[]; pending: { id: string; deviceKey: string; card: string }[]; device?: Device; busy: boolean; scanning: boolean; stage: string; error?: string; logs: string[]; language: 'zh' | 'en'; theme: string };
export const initial: State = { cards: [], pending: [], busy: false, scanning: false, stage: 'ready', logs: [], language: (localStorage.getItem('language') || (navigator.language.startsWith('zh') ? 'zh' : 'en')) as 'zh' | 'en', theme: localStorage.getItem('theme') || 'system' };
type Action = { type: 'patch'; value: Partial<State> } | { type: 'stage'; value: string };
export function reducer(state: State, action: Action): State { return action.type === 'patch' ? { ...state, ...action.value } : { ...state, stage: action.value, logs: [...state.logs.slice(-99), action.value] }; }
const Context = createContext<{ state: State; dispatch: React.Dispatch<Action>; run: (method: string, params?: Record<string, unknown>) => Promise<any>; t: (key: string) => string }>(null!);
export function Provider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initial);
  const t = (key: string) => (state.language === 'zh' ? zh : en)[key as Key] || (state.language === 'zh' ? zh : en).OPERATION_FAILED;
  async function refresh() { const data = await request('overview'); dispatch({ type: 'patch', value: { cards: data.cards, pending: data.pending, busy: !!data.active, scanning: !!data.scanning } }); }
  async function run(method: string, params: Record<string, unknown> = {}) {
    dispatch({ type: 'patch', value: { error: undefined } });
    const operation = method.startsWith('card.') && method !== 'card.export' || method === 'recovery.resume';
    if (operation) dispatch({ type: 'patch', value: { busy: true } });
    try {
      const result = await request(method, params);
      if (method === 'device') dispatch({ type: 'patch', value: { device: result } });
      if (method === 'scan.start' || method === 'scan.stop') dispatch({ type: 'patch', value: { scanning: result.scanning } });
      if (operation) { await refresh(); dispatch({ type: 'stage', value: 'success' }); }
      return result;
    } catch (error) {
      const code = error instanceof Error ? error.message : 'OPERATION_FAILED';
      dispatch({ type: 'patch', value: { error: code, ...(method === 'device' ? { device: undefined } : {}) } });
      if (operation) await refresh().catch(() => {});
      return undefined;
    } finally { if (operation) dispatch({ type: 'patch', value: { busy: false } }); }
  }
  useEffect(() => {
    const unsubscribe = subscribe(message => {
      if (message.event === 'progress') { dispatch({ type: 'stage', value: message.stage! }); dispatch({ type: 'patch', value: { busy: true } }); }
      if (message.event === 'changed') void refresh();
      if (message.event === 'candidate') dispatch({ type: 'stage', value: 'candidates' });
      if (message.event === 'scanStopped') dispatch({ type: 'patch', value: { scanning: false } });
      if (message.event === 'scanError' || message.event === 'fatal') dispatch({ type: 'patch', value: { error: message.code, busy: false } });
      if (message.event === 'closing') { dispatch({ type: 'stage', value: 'closing' }); dispatch({ type: 'patch', value: { busy: true } }); }
    });
    void request('hello').then(data => dispatch({ type: 'patch', value: { cards: data.cards, pending: data.pending, busy: !!data.active, scanning: !!data.scanning } })).catch(() => dispatch({ type: 'patch', value: { error: 'BACKEND_OFFLINE' } }));
    void run('device');
    return unsubscribe;
  }, []);
  useEffect(() => { localStorage.setItem('language', state.language); document.documentElement.lang = state.language === 'zh' ? 'zh-CN' : 'en'; }, [state.language]);
  useEffect(() => { localStorage.setItem('theme', state.theme); document.documentElement.dataset.theme = state.theme; }, [state.theme]);
  return <Context.Provider value={{ state, dispatch, run, t }}>{children}</Context.Provider>;
}
export const useApp = () => useContext(Context);
