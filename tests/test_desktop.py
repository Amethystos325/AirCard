import asyncio
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from PIL import Image
from backend.aircard_desktop.engine import Engine
from backend.aircard_desktop.storage import Store, read, save, identity
from backend.aircard_desktop.service import Server
from backend.aircard_desktop.worker import validate, target, ART, CACHE, SCANNED_CARD
from backend.aircard_desktop.images import prepare
from backend.aircard_desktop.transport import Session, native

CARD = 'A' * 27 + '='


def png(color='blue'):
    output = io.BytesIO()
    Image.new('RGB', (64, 40), color).save(output, 'PNG')
    return output.getvalue()


class MemorySession:
    files = {}
    fail = False
    writes = []
    finished = 0
    def __init__(self, store, state): self.state = state
    async def __aenter__(self): return self
    async def __aexit__(self, *args): pass
    async def read(self, area, leaf): return self.files.get((area, leaf))
    async def write(self, area, leaf, data):
        self.writes.append((area, leaf, data))
        if data is None: self.files.pop((area, leaf), None)
        else: self.files[(area, leaf)] = data
        if type(self).fail:
            type(self).fail = False
            raise RuntimeError('WRITE_NOT_VERIFIED')
    async def recover_pending(self): pass
    async def finish(self): type(self).finished += 1


class DesktopTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = Store(self.root)
        self.engine = Engine(self.store, MemorySession)
        MemorySession.files = {('pkpass', 'pass.json'): json.dumps({'paymentCard': {}, 'organizationName': 'Test Suica'}).encode(),
                               ('pkpass', 'cardBackgroundCombined@3x.png'): png(),
                               ('cache', 'FrontFace'): b'original-cache'}
        MemorySession.fail, MemorySession.writes, MemorySession.finished = False, [], 0

    async def classify(self):
        await self.engine.operate('device-a', CARD, 'classify')

    async def test_complete_cycle_preserves_first_backup_and_absence(self):
        await self.classify()
        original = MemorySession.files.copy()
        await self.engine.operate('device-a', CARD, 'read')
        source = self.root / '新 卡面.png'; source.write_bytes(png('red'))
        prepared = self.engine.prepare_image(str(source))
        await self.engine.operate('device-a', CARD, 'apply', prepared['imageId'])
        self.assertNotEqual(MemorySession.files[('pkpass', 'cardBackgroundCombined@3x.png')], original[('pkpass', 'cardBackgroundCombined@3x.png')])
        self.assertNotIn(('cache', 'FrontFace'), MemorySession.files)
        await self.engine.operate('device-a', CARD, 'restore')
        self.assertEqual(MemorySession.files[('pkpass', 'cardBackgroundCombined@3x.png')], original[('pkpass', 'cardBackgroundCombined@3x.png')])
        self.assertNotIn(('pkpass', 'cardBackgroundCombined@2x.png'), MemorySession.files)
        self.assertFalse(self.store.pending())

    async def test_partial_write_rolls_back_all_originals(self):
        await self.classify(); before = MemorySession.files.copy()
        source = self.root / 'new.png'; source.write_bytes(png('red'))
        prepared = self.engine.prepare_image(str(source))
        MemorySession.fail = True
        with self.assertRaisesRegex(RuntimeError, 'WRITE_NOT_VERIFIED'):
            await self.engine.operate('device-a', CARD, 'apply', prepared['imageId'])
        self.assertEqual(MemorySession.files, before)
        self.assertFalse(self.store.pending())
        self.assertTrue(any(s['status'] == 'rolled_back' for s in self.store.transactions()))

    async def test_corrupt_original_backup_prevents_writes(self):
        await self.classify()
        await self.engine.operate('device-a', CARD, 'read')
        directory = self.store.card('device-a', CARD) / 'original'
        next(directory.glob('*.bin')).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'INVALID_BACKUP'):
            await self.engine.operate('device-a', CARD, 'restore')
        self.assertFalse(MemorySession.writes)

    async def test_devices_never_share_originals(self):
        await self.classify(); await self.engine.operate('device-a', CARD, 'read')
        self.assertNotEqual(self.store.card('device-a', CARD), self.store.card('device-b', CARD))
        with self.assertRaisesRegex(ValueError, 'INVALID_BACKUP'):
            self.engine.load_manifest(self.store.card('device-a', CARD) / 'original', 'device-b', CARD)

    async def test_incomplete_transaction_blocks_other_writes_and_resumes(self):
        state = {'id': 'a'*32, 'device': 'device-a', 'deviceKey': identity('device-a'), 'card': CARD,
                 'mode': 'read', 'status': 'needs_recovery', 'originals': {}, 'writeStarted': False}
        self.store.checkpoint(state)
        with self.assertRaisesRegex(RuntimeError, 'RECOVERY_REQUIRED'):
            await self.engine.operate('device-a', CARD, 'read')
        await self.engine.recover(state['id'])
        self.assertFalse(self.store.pending())

    async def test_unresolved_prewrite_can_be_isolated_without_losing_recovery_record(self):
        class IsolatingSession(MemorySession):
            isolated = False
            async def isolate_unresolved(inner):
                type(inner).isolated = True
        state = {'id': 'a'*32, 'device': 'device-a', 'deviceKey': identity('device-a'), 'card': CARD,
                 'mode': 'classify', 'status': 'needs_recovery', 'originals': {}, 'writeStarted': False}
        self.store.checkpoint(state)
        save(self.root / 'transactions' / state['id'] / 'transport' / 'journal.json',
             {'pending': {'replayAttempted': True}})
        self.engine.session_type = IsolatingSession
        self.assertTrue(self.engine.overview()['pending'][0]['canIsolate'])
        await self.engine.isolate_unresolved(state['id'])
        self.assertTrue(IsolatingSession.isolated)
        self.assertFalse(self.store.pending())
        self.assertTrue(self.store.quarantined_card('device-a', CARD))
        self.assertEqual(len(self.engine.overview()['unresolved']), 1)
        self.assertEqual(read(self.root / 'transactions' / state['id'] / 'transport' / 'journal.json')['pending'],
                         {'replayAttempted': True})

    async def test_started_write_cannot_be_isolated(self):
        state = {'id': 'a'*32, 'device': 'device-a', 'deviceKey': identity('device-a'), 'card': CARD,
                 'mode': 'apply', 'status': 'needs_recovery', 'originals': {}, 'writeStarted': True}
        self.store.checkpoint(state)
        with self.assertRaisesRegex(RuntimeError, 'RECOVERY_REQUIRED'):
            await self.engine.isolate_unresolved(state['id'])
        self.assertEqual(self.store.pending()[0]['id'], state['id'])

    async def test_archived_unresolved_keeps_card_quarantined_without_blocking_other_cards(self):
        state = {'id': 'a'*32, 'device': 'device-a', 'deviceKey': identity('device-a'), 'card': CARD,
                 'mode': 'classify', 'status': 'archived_unresolved', 'originals': {}, 'writeStarted': False}
        self.store.checkpoint(state)
        self.assertFalse(self.store.pending('device-a'))
        self.assertTrue(self.store.quarantined_card('device-a', CARD))
        with self.assertRaisesRegex(RuntimeError, 'CARD_QUARANTINED'):
            await self.engine.operate('device-a', CARD, 'classify')
        other = 'B' * 27 + '='
        self.assertFalse(self.store.quarantined_card('device-a', other))
        await self.engine.operate('device-a', other, 'classify')

    async def test_busy_rejects_competing_operation(self):
        async with self.engine.lock:
            with self.assertRaisesRegex(RuntimeError, 'BUSY'):
                await self.engine.operate('device-a', CARD, 'read')

    async def test_protocol_replays_id_without_repeating_action(self):
        output = []; server = Server(output.append, self.engine)
        message = {'v': 1, 'id': 'same', 'method': 'card.classify', 'params': {'device': 'device-a', 'card': CARD}}
        await server.handle(message); count = MemorySession.finished
        await server.handle(message)
        self.assertEqual(MemorySession.finished, count)
        self.assertEqual(output[-1], output[-2])
        await server.handle({'v': 3, 'id': 'bad', 'method': 'hello'})
        self.assertEqual(output[-1]['error']['code'], 'INVALID_REQUEST')

    async def test_read_cancellation_restores_and_retains_no_pending(self):
        class CancelSession(MemorySession):
            async def read(inner, area, leaf):
                data = await super(CancelSession, inner).read(area, leaf)
                self.engine.cancel_requested = True
                return data
        await self.classify(); self.engine.session_type = CancelSession
        with self.assertRaisesRegex(RuntimeError, 'CANCELLED'):
            await self.engine.operate('device-a', CARD, 'read')
        self.assertFalse(self.store.pending())

    def test_image_crop_output_and_bad_bounds(self):
        source = self.root / 'image.webp'; Image.new('RGB', (200, 100), 'green').save(source)
        output = self.root / 'prepared.png'
        prepare(source, output, {'x': .1, 'y': .1, 'width': .8, 'height': .8})
        with Image.open(output) as image: self.assertEqual(image.size, (1536, 969))
        with self.assertRaisesRegex(ValueError, 'INVALID_CROP'):
            prepare(source, output, {'x': .8, 'y': 0, 'width': .8, 'height': 1})

    def test_store_rejects_a_second_transaction_handle(self):
        other = Store(self.root)
        with self.store.operation_lock():
            with self.assertRaisesRegex(RuntimeError, 'BUSY'):
                with other.operation_lock():
                    pass
        with other.operation_lock():
            pass

    def test_native_worker_rejects_path_escalation(self):
        with self.assertRaises(ValueError): target('../../invalid', 'pkpass', 'pass.json')
        with self.assertRaises(ValueError): target(CARD, 'pkpass', '../secret')
        token = 'a'*32; link=f'aircard-probe-{token}-link-0'; source=f'aircard-probe-{token}-source-0'
        job = {'card': CARD, 'area': 'pkpass', 'leaf': 'pass.json', 'token': token, 'direction': 'push',
               'assets': [[f'../../{source}/p0/p1/p2/link',link],[f'../../{source}/payload',link+'/pass.json']]}
        validate(job)
        job['assets'][1][1] += '/../unrelated'
        with self.assertRaises(ValueError): validate(job)

    def test_scanner_rejects_its_own_probe_paths(self):
        self.assertTrue(SCANNED_CARD.fullmatch(CARD))
        self.assertFalse(SCANNED_CARD.fullmatch('aircard-export-probe-b379e736c430'))

    def test_recovery_worker_accepts_only_the_pending_asset(self):
        token = 'a' * 32
        link = f'aircard-probe-{token}-link-0'
        recovered = f'aircard-probe-{token}-recovered-0'
        job = {'card': CARD, 'area': 'pkpass', 'leaf': 'pass.json', 'token': token,
               'direction': 'recover', 'assets': [[f'../../{link}/pass.json', recovered]]}
        validate(job)
        job['assets'].append(['../../unrelated/pass.json', 'unrelated'])
        with self.assertRaises(ValueError): validate(job)

    async def test_pending_remote_copy_must_match_saved_checksum(self):
        from backend.aircard_desktop.storage import sha
        session = Session(self.store, {'id': 'b'*32, 'card': CARD, 'device': 'device-a'})
        session.journal['pending'] = {'area': 'pkpass', 'leaf': 'pass.json', 'recovered': 'retained', 'sha256': sha(b'original')}
        session.afc = AsyncMock(); session.afc.exists.return_value = True
        session.transfer = AsyncMock()
        with patch('backend.aircard_desktop.transport.bounded_file', AsyncMock(return_value=b'corrupt')):
            with self.assertRaisesRegex(RuntimeError, 'INVALID_BACKUP'):
                await session.recover_pending()
        session.transfer.assert_not_awaited()
        self.assertIsNotNone(session.journal['pending'])

    async def test_worker_timeout_is_killed_and_job_file_removed(self):
        process = AsyncMock(); process.returncode = None
        process.kill = __import__('unittest.mock', fromlist=['Mock']).Mock()
        process.communicate.side_effect = TimeoutError()
        with patch('asyncio.create_subprocess_exec', AsyncMock(return_value=process)) as spawn:
            with self.assertRaises(TimeoutError):
                await native({'checkSync': True}, self.root)
        self.assertEqual(spawn.call_args.kwargs['stdin'], asyncio.subprocess.DEVNULL)
        process.kill.assert_called_once()
        self.assertFalse(list(self.root.glob('native-*.json')))

    async def test_interrupted_move_uses_verified_before_snapshot_for_rollback(self):
        state = {'id': 'c'*32, 'card': CARD, 'device': 'device-a', 'writeStarted': True, 'originals': {}}
        session = Session(self.store, state)
        state['originals']['pkpass/cardBackgroundCombined@2x.png'] = self.store.blob(session.directory.parent / 'before', 'asset', b'blue-before-restore')
        session.journal['pending'] = {'area': 'pkpass', 'leaf': 'cardBackgroundCombined@2x.png', 'recovered': 'missing'}
        session.afc = AsyncMock(); session.afc.exists.return_value = False
        session.transfer = AsyncMock()
        await session.recover_pending()
        session.transfer.assert_awaited_once_with('pkpass', 'cardBackgroundCombined@2x.png', 'push', b'blue-before-restore')
        self.assertIsNone(session.journal['pending'])

    async def test_uncertain_pull_replays_existing_sync_once_and_keeps_recovery(self):
        token = 'd' * 32
        source, link, recovered = (f'aircard-probe-{token}-{kind}-0' for kind in ('source', 'link', 'recovered'))
        state = {'id': 'e' * 32, 'card': CARD, 'device': 'device-a', 'writeStarted': False}
        session = Session(self.store, state)
        session.snapshot = {}
        session.runtime = None
        session.journal = {'roots': [source, link, recovered],
                           'identifiers': [f'../../{source}/p0/p1/p2/link', f'../../{link}/pass.json'],
                           'pending': {'area': 'pkpass', 'leaf': 'pass.json', 'recovered': recovered}}
        session.afc = AsyncMock()
        session.afc.exists.side_effect = lambda path: path != recovered
        session.afc.stat.return_value = {'st_ifmt': 'S_IFLNK'}

        async def remote_bytes(_afc, path, *_args):
            return b'aircard-desktop-staging' if path == source + '/payload' else b'canary'

        with patch('backend.aircard_desktop.transport.bounded_file', remote_bytes), \
             patch('backend.aircard_desktop.transport.canary_books', return_value=b'canary'), \
             patch('backend.aircard_desktop.transport.native', AsyncMock()) as replay:
            with self.assertRaisesRegex(RuntimeError, 'RECOVERY_INDETERMINATE'):
                await session.recover_pending()
            with self.assertRaisesRegex(RuntimeError, 'RECOVERY_INDETERMINATE'):
                await session.recover_pending()
        replay.assert_awaited_once()
        self.assertEqual(replay.await_args.args[0]['assets'], [[f'../../{link}/pass.json', recovered]])
        self.assertEqual(replay.await_args.args[0]['direction'], 'recover')
        self.assertTrue(session.journal['pending']['replayAttempted'])
        self.assertEqual(read(session.directory / 'journal.json')['pending'], session.journal['pending'])

    async def test_uncertain_pull_replay_can_restore_a_late_copy(self):
        token = 'f' * 32
        source, link, recovered = (f'aircard-probe-{token}-{kind}-0' for kind in ('source', 'link', 'recovered'))
        state = {'id': '1' * 32, 'card': CARD, 'device': 'device-a', 'writeStarted': False}
        session = Session(self.store, state)
        session.snapshot = {}
        session.runtime = None
        session.journal = {'roots': [source, link, recovered],
                           'identifiers': [f'../../{source}/p0/p1/p2/link', f'../../{link}/pass.json'],
                           'pending': {'area': 'pkpass', 'leaf': 'pass.json', 'recovered': recovered}}
        session.afc = AsyncMock()
        moved = False
        session.afc.exists.side_effect = lambda path: moved if path == recovered else True
        session.afc.stat.return_value = {'st_ifmt': 'S_IFLNK'}
        session.transfer = AsyncMock()

        async def remote_bytes(_afc, path, *_args):
            if path == source + '/payload': return b'aircard-desktop-staging'
            if path == 'Books/Sync/Books.plist': return b'canary'
            return b'original'

        async def replay(_job, _directory):
            nonlocal moved
            moved = True

        with patch('backend.aircard_desktop.transport.bounded_file', remote_bytes), \
             patch('backend.aircard_desktop.transport.canary_books', return_value=b'canary'), \
             patch('backend.aircard_desktop.transport.native', replay):
            await session.recover_pending()
        session.transfer.assert_awaited_once_with('pkpass', 'pass.json', 'push', b'original')
        self.assertIsNone(session.journal['pending'])

    async def test_isolation_restores_books_but_keeps_staging_and_pending_copy(self):
        state = {'id': 'a'*32, 'card': CARD, 'device': 'device-a', 'writeStarted': False}
        session = Session(self.store, state)
        session.snapshot = {'files': {}, 'directories': {}}
        session.journal['pending'] = {'area': 'pkpass', 'leaf': 'pass.json', 'recovered': 'retained',
                                      'replayAttempted': True}
        session.afc = AsyncMock()
        session.afc.exists.return_value = False
        with patch('backend.aircard_desktop.transport.restore_books', AsyncMock()) as restore, \
             patch('backend.aircard_desktop.transport.books_match', AsyncMock(return_value=True)):
            await session.isolate_unresolved()
        restore.assert_awaited_once()
        self.assertIsNotNone(session.journal['pending'])
        self.assertTrue(read(session.directory / 'journal.json')['booksRestoredForUnresolved'])

    async def test_known_export_probe_does_not_leave_recovery_pending(self):
        state = {'id': 'a'*32, 'card': 'aircard-export-probe-b379e736c430',
                 'device': 'device-a', 'mode': 'classify', 'writeStarted': False}
        session = Session(self.store, state)
        session.journal['roots'] = ['source', 'link', 'missing']
        session.journal['pending'] = {'area': 'pkpass', 'leaf': 'pass.json', 'recovered': 'missing'}
        session.afc = AsyncMock()
        session.afc.exists.return_value = False
        session.transfer = AsyncMock()
        await session.recover_pending()
        self.assertIsNone(session.journal['pending'])
        session.transfer.assert_not_awaited()

    async def test_worker_crash_has_stable_error_and_retains_no_job(self):
        process = AsyncMock(); process.returncode = 5
        process.communicate.return_value = (b'partial output', b'failure')
        with patch('asyncio.create_subprocess_exec', AsyncMock(return_value=process)):
            with self.assertRaisesRegex(RuntimeError, 'SYNC_FAILED'):
                await native({'checkSync': True}, self.root)
        self.assertFalse(list(self.root.glob('native-*.json')))

    async def test_shutdown_rejects_new_device_work(self):
        server = Server(lambda _: None, self.engine)
        self.assertTrue((await server.dispatch('shutdown', {}))['safeToExit'])
        with self.assertRaisesRegex(RuntimeError, 'CLOSING'):
            await server.dispatch('card.read', {'device': 'device-a', 'card': CARD})
        self.assertIsNone((await server.dispatch('overview', {}))['active'])

    def test_pdf_only_artwork_gets_preview(self):
        from backend.card_assets import build_card_assets
        from backend.aircard_desktop.images import artwork_preview
        assets = dict(build_card_assets(png()))
        preview = artwork_preview({'cardBackgroundCombined.pdf': assets['cardBackgroundCombined.pdf']})
        with Image.open(io.BytesIO(preview)) as image:
            self.assertGreater(image.width, 100)

    async def test_removing_existing_file_verifies_absence(self):
        session = Session(self.store, {'id': 'd'*32, 'card': CARD, 'device': 'device-a'})
        session.transfer = AsyncMock(side_effect=[b'old image', None])
        await session.write('pkpass', 'cardBackgroundCombined@2x.png', None)
        self.assertEqual(session.transfer.await_count, 2)
        self.assertIsNone(session.journal['pending'])

    @unittest.skipUnless(__import__('sys').platform == 'win32', 'Windows sharing semantics')
    def test_atomic_replace_retries_transient_windows_share_denial(self):
        from backend.aircard_desktop.storage import put
        import os
        replace = os.replace
        error = PermissionError('sharing violation'); error.winerror = 32
        calls = []
        def shared(source, destination):
            calls.append(destination)
            if len(calls) == 1: raise error
            return replace(source, destination)
        with patch('backend.aircard_desktop.storage.os.replace', side_effect=shared):
            put(self.root / 'journal.json', b'verified')
        self.assertEqual((self.root / 'journal.json').read_bytes(), b'verified')

    def test_legacy_import_does_not_create_device_backup(self):
        from backend.aircard_desktop.migration import import_legacy
        source = self.root / '.aircard_cards.json'
        source.write_text(json.dumps([CARD]))
        rows = import_legacy(self.store, self.root, self.root / 'empty-cache')
        self.assertEqual(rows, [{'card': CARD, 'status': 'unassigned'}])
        self.assertTrue(source.is_file())
        self.assertFalse((self.store.root / 'devices').exists())
        self.assertEqual(rows, import_legacy(self.store, self.root))

if __name__ == '__main__': unittest.main()
