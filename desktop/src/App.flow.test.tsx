import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { afterEach, beforeEach, it, expect, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ request: vi.fn(), open: vi.fn() }));
vi.mock('./bridge', () => ({ demo: false, request: mocks.request, subscribe: () => () => {} }));
vi.mock('@tauri-apps/plugin-dialog', () => ({ open: mocks.open, save: vi.fn() }));
vi.mock('@tauri-apps/api/webview', () => ({ getCurrentWebview: () => ({ onDragDropEvent: async () => () => {} }) }));
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
