import { invoke, isTauri } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
export type Message = { v: number; id?: string; ok?: boolean; result?: any; error?: { code: string }; event?: string; code?: string; stage?: string; operationId?: string };
const waiting = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
const subscribers = new Set<(message: Message) => void>();
let started: Promise<unknown> | undefined;
export const demo = !isTauri();
export function receive(message: Message) {
  if (message.id && waiting.has(message.id)) {
    const promise = waiting.get(message.id)!; waiting.delete(message.id);
    message.ok ? promise.resolve(message.result) : promise.reject(new Error(message.error?.code || 'OPERATION_FAILED'));
  }
  if (message.event === 'fatal') { for (const promise of waiting.values()) promise.reject(new Error(message.code)); waiting.clear(); }
  for (const listener of subscribers) listener(message);
}
export function subscribe(callback: (message: Message) => void) { subscribers.add(callback); return () => { subscribers.delete(callback); }; }
export async function request(method: string, params: Record<string, unknown> = {}): Promise<any> {
  if (demo) {
    if (method === 'hello' || method === 'overview') return { cards: [], pending: [], active: null };
    if (method === 'device') throw new Error('NO_DEVICE');
    throw new Error('BACKEND_OFFLINE');
  }
  started ??= listen<Message>('backend-message', e => receive(e.payload));
  await started;
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    waiting.set(id, { resolve, reject });
    invoke('backend_send', { request: { v: 1, id, method, params } }).catch(error => { waiting.delete(id); reject(new Error(String(error))); });
  });
}
