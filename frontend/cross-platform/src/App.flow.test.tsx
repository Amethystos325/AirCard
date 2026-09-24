import { render, screen, fireEvent, waitFor, cleanup, act } from '@testing-library/react';
import { afterEach, beforeEach, it, expect, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ request: vi.fn(), open: vi.fn(), drop: undefined as undefined | ((event: any) => void) }));
vi.mock('./bridge', () => ({ demo: false, request: mocks.request, subscribe: () => () => {} }));
vi.mock('@tauri-apps/plugin-dialog', () => ({ open: mocks.open, save: vi.fn() }));
vi.mock('@tauri-apps/api/webview', () => ({ getCurrentWebview: () => ({ onDragDropEvent: async (listener: (event: any) => void) => { mocks.drop = listener; return () => {}; } }) }));
import App from './App';
import { Provider } from './state';
const card = { card: 'A'.repeat(28), deviceKey: 'device-key', label: 'Test Suica', kind: 'secure-element', backup: true };
beforeEach(() => {
  HTMLDialogElement.prototype.showModal = vi.fn();
  mocks.request.mockReset(); mocks.open.mockResolvedValue('C:/测试 图片.webp');
  mocks.request.mockImplementation(async method => {
    if (method === 'hello' || method === 'overview') return { cards: [card], pending: [], active: null };
    if (method === 'device') return { id: 'device', key: 'device-key', name: 'iPhone', compatible: true };
    if (method === 'image.inspect') return { width: 1536, height: 969, preview: 'data:image/png;base64,AA==' };
    if (method === 'image.prepare') return { imageId: 'prepared-image', preview: 'data:image/png;base64,AA==' };
    return {};
  });
});
afterEach(cleanup);
it('selects and crops locally, requiring an explicit apply click before device writes', async () => {
  render(<Provider><App/></Provider>);
  fireEvent.click(await screen.findByRole('button', { name: 'Select a card Test Suica' }));
  const choose = screen.getAllByRole('button', { name: 'Choose image', hidden: true })[0];
  fireEvent.click(choose);
  await waitFor(() => expect(mocks.request).toHaveBeenCalledWith('image.inspect', { path: 'C:/测试 图片.webp' }));
  expect(mocks.request.mock.calls.some(([m]) => m === 'card.apply')).toBe(false);
  const apply = screen.getByRole('button', { name: 'Apply artwork', hidden: true });
  expect(apply).toBeDisabled();
  fireEvent.click(screen.getByRole('button', { name: 'Prepare preview', hidden: true }));
  await waitFor(() => expect(apply).toBeEnabled());
  expect(mocks.request.mock.calls.some(([m]) => m === 'card.apply')).toBe(false);
  fireEvent.click(apply);
  await waitFor(() => expect(mocks.request).toHaveBeenCalledWith('card.apply', { device: 'device', card: card.card, imageId: 'prepared-image' }));
});

it('opens the cached artwork viewer without issuing a device operation', async () => {
  mocks.request.mockImplementation(async method => {
    if (method === 'hello' || method === 'overview') return { cards: [{ ...card, preview: 'data:image/png;base64,AA==' }], pending: [], active: null };
    if (method === 'device') return { id: 'device', key: 'device-key', name: 'iPhone', compatible: true };
    return {};
  });
  render(<Provider><App/></Provider>);
  fireEvent.click(await screen.findByRole('button', { name: 'View artwork Test Suica' }));
  expect(screen.getByRole('slider', { name: 'Zoom', hidden: true })).toHaveValue('1');
  fireEvent.click(screen.getByRole('button', { name: 'Zoom in', hidden: true }));
  expect(screen.getByRole('slider', { name: 'Zoom', hidden: true })).toHaveValue('1.25');
  expect(mocks.request.mock.calls.some(([m]) => m.startsWith('card.'))).toBe(false);
});

it('hides a card locally and brings it back without deleting its backup', async () => {
  render(<Provider><App/></Provider>);
  fireEvent.click(await screen.findByRole('button', { name: 'Hide from this list Test Suica' }));
  expect(screen.queryByText('Test Suica')).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Show hidden cards' }));
  expect(screen.getByText('Test Suica')).toBeInTheDocument();
  expect(mocks.request.mock.calls.some(([m]) => m.startsWith('card.'))).toBe(false);
});

it('runs the inline read action and prevents a second read while it is pending', async () => {
  let finish!: (value: unknown) => void;
  const original = mocks.request.getMockImplementation()!;
  mocks.request.mockImplementation((method, params) => method === 'card.read' ? new Promise(resolve => { finish = resolve; }) : original(method, params));
  render(<Provider><App/></Provider>);
  const read = await screen.findByRole('button', { name: 'Read artwork' });
  await waitFor(() => expect(read).toBeEnabled());
  fireEvent.click(read);
  await waitFor(() => expect(read).toBeDisabled());
  expect(mocks.request).toHaveBeenCalledWith('card.read', { device: 'device', card: card.card });
  finish({});
  await waitFor(() => expect(read).toBeEnabled());
});

it('routes a native drop on a card into image preview without applying it', async () => {
  render(<Provider><App/></Provider>);
  const face = await screen.findByRole('button', { name: 'Select a card Test Suica' });
  const previous = Object.getOwnPropertyDescriptor(document, 'elementFromPoint');
  Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => face });
  try {
    await act(async () => { mocks.drop?.({ payload: { type: 'drop', position: { x: 20, y: 20 }, paths: ['C:/拖入 图片.png'] } }); });
    await waitFor(() => expect(mocks.request).toHaveBeenCalledWith('image.inspect', { path: 'C:/拖入 图片.png' }));
    expect(screen.getByRole('button', { name: 'Apply artwork', hidden: true })).toBeDisabled();
    expect(mocks.request.mock.calls.some(([m]) => m === 'card.apply')).toBe(false);
  } finally {
    if (previous) Object.defineProperty(document, 'elementFromPoint', previous);
    else Reflect.deleteProperty(document, 'elementFromPoint');
  }
});
