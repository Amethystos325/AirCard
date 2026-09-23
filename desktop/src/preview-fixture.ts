// Synthetic artwork for local visual review. Never reads a device or backup.
const artwork = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="580" height="364" viewBox="0 0 580 364"><rect width="580" height="364" fill="#92c74e"/><path d="M-30 130 Q290 250 610 130 L610 370 H-30Z" fill="#f4f5eb"/><text x="38" y="72" fill="#1d4530" font-family="sans-serif" font-size="26" font-weight="bold">Transit</text><text x="38" y="324" fill="#667165" font-family="sans-serif" font-size="15">AIRCard · PREVIEW</text><circle cx="450" cy="247" r="46" fill="#294835"/><circle cx="435" cy="237" r="6" fill="white"/><circle cx="465" cy="237" r="6" fill="white"/><path d="M433 262 Q450 274 467 262" fill="none" stroke="white" stroke-width="5"/></svg>`)}`;
export const previewDevice = { id: 'preview', key: 'preview-device', name: 'iPhone', product: 'iPhone 13 Pro', version: '27.0', build: 'Preview', compatible: true };
export const previewCards = [
  { card: 'A1B2C3D4'.repeat(4), deviceKey: previewDevice.key, label: 'Transit', kind: 'secure-element', backup: true, preview: artwork },
  { card: 'E5F6A7B8'.repeat(4), deviceKey: previewDevice.key, label: 'Card #2', kind: 'secure-element', backup: false },
];
