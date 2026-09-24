import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { afterEach, describe, it, expect } from 'vitest';
import App from './App';
import { Provider, reducer, initial } from './state';
import { en, zh } from './i18n';
afterEach(cleanup);
describe('desktop', () => {
  it('keeps disconnected writes unavailable and explains how to connect', async () => {
    render(<Provider><App/></Provider>);
    expect(await screen.findByText(en.offline)).toBeInTheDocument();
    for (const button of screen.getAllByRole('button', { name: /Scan Cards|Start Scanning/ })) expect(button).toBeDisabled();
    expect(screen.queryByRole('button', { name: en.apply })).not.toBeInTheDocument();
  });
  it('switches the complete interface language', () => {
    render(<Provider><App/></Provider>);
    fireEvent.change(screen.getByLabelText(en.language), { target: { value: 'zh' } });
    expect(screen.getByRole('main', { name: zh.cards })).toBeInTheDocument();
    expect(Object.keys(zh).sort()).toEqual(Object.keys(en).sort());
  });
  it('bounds the event log and preserves card state', () => {
    let state = { ...initial, logs: Array(100).fill('writing') };
    state = reducer(state, { type: 'stage', value: 'cleaning' });
    expect(state.logs).toHaveLength(100); expect(state.stage).toBe('cleaning');
  });
});
