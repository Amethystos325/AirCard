import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


class ProtocolProcessTests(unittest.TestCase):
    def test_fragmented_invalid_replayed_and_oversized_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parents[1] / 'desktop_backend.py')],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={**os.environ, 'AIRCARD_DATA_DIR': directory})
            responses = queue.Queue()
            def collect():
                for line in process.stdout:
                    responses.put(json.loads(line))
            thread = threading.Thread(target=collect, daemon=True); thread.start()
            try:
                process.stdin.write(b'{"v":1,"id":"fragment",'); process.stdin.flush()
                with self.assertRaises(queue.Empty): responses.get(timeout=.2)
                process.stdin.write(b'"method":"overview","params":{}}\n'); process.stdin.flush()
                result = responses.get(timeout=15)
                self.assertTrue(result['ok']); self.assertEqual(result['id'], 'fragment')
                process.stdin.write(b'invalid\n'); process.stdin.flush()
                self.assertEqual(responses.get(timeout=5)['error']['code'], 'INVALID_JSON')
                process.stdin.write(b'{"v":1,"id":"fragment","method":"invalid"}\n'); process.stdin.flush()
                self.assertEqual(responses.get(timeout=5), result)
                # The tail of an oversized message must never become a new request.
                process.stdin.write(b'x' * (4 * 1024 * 1024) + b'{"v":1,"id":"tail","method":"overview"}\n')
                process.stdin.write(b'{"v":1,"id":"after","method":"overview"}\n'); process.stdin.flush()
                self.assertEqual(responses.get(timeout=10)['error']['code'], 'INVALID_JSON')
                self.assertEqual(responses.get(timeout=5)['id'], 'after')
                process.stdin.close(); process.wait(timeout=15)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None: process.kill(); process.wait()
                process.stdout.close(); process.stderr.close()


if __name__ == '__main__': unittest.main()
