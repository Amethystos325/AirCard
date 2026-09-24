"""Copy legacy data as unassigned candidates. Never create a restore manifest."""
from pathlib import Path
from backend.card_cache import CACHE_ROOT, get_cached_card
from .storage import read, save, put, identity
from .worker import CARD


def import_legacy(store, home=None, cache_root=None):
    destination = store.root / 'legacy'
    if (destination / 'import.json').exists():
        return read(destination / 'import.json')['candidates']
    home = home or Path.home()
    candidates = set()
    for filename in ('.aircard_cards.json', '.lumicards_cards.json'):
        source = home / filename
        if not source.is_file():
            continue
        try:
            payload = read(source)
            rows = payload if isinstance(payload, list) else payload.get('cards', [])
            for row in rows:
                card = row if isinstance(row, str) else row.get('hash', row.get('cardHash', ''))
                if CARD.fullmatch(card):
                    candidates.add(card)
            put(destination / filename, source.read_bytes())
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    for card in candidates:
        cached = get_cached_card(card, cache_root=cache_root or CACHE_ROOT)
        if cached:
            for name, path in cached['files'].items():
                put(destination / 'cache' / identity(card)[:32] / name, Path(path).read_bytes())
    rows = [{'card': card, 'status': 'unassigned'} for card in sorted(candidates)]
    save(destination / 'import.json', {'version': 1, 'candidates': rows})
    return rows
