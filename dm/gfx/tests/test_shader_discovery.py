"""Discovery and mixed scan scheduling overlap while preserving main/archive/loose source precedence."""
import concurrent.futures as cf
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import shader_split as split


class Discovery(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(split, 'scan_inputs'), 'discovery still runs before the worker pool')

    def test_main_discovery_and_both_scan_groups_overlap_without_reordering(self):
        loose_done = threading.Event(); main_started = threading.Event(); archive_started = threading.Event()
        def mains(*_):
            main_started.set()
            if not loose_done.wait(5): raise TimeoutError('main scan blocked later work')
            return [('main', 'first'), ('main-update', 'second')]
        def archives(_):
            if not main_started.wait(5): raise TimeoutError('main and archive discovery did not overlap')
            return ['archive'], ['loose']
        def scan(job):
            if job == 'archive':
                archive_started.set()
                if not loose_done.wait(5): raise TimeoutError('archive queue blocked loose files')
            else:
                if not archive_started.wait(5): raise TimeoutError('archive job never started')
                loose_done.set()
            return job
        out = io.StringIO()
        with mock.patch.object(split, 'scan_mains', mains), mock.patch.object(split, 'archive_jobs', archives), \
                mock.patch.object(split, 'scan_file', scan), cf.ThreadPoolExecutor(3) as pool, contextlib.redirect_stdout(out):
            try: result = split.scan_inputs(pool, [], [], b'')
            finally: loose_done.set()
        self.assertEqual(result, [('main', 'first'), ('main-update', 'second'), 'archive', 'loose'])
        self.assertIn('progress: 2/2', out.getvalue())

    def test_discovery_errors_reach_the_caller(self):
        with mock.patch.object(split, 'scan_mains', return_value=[]), mock.patch.object(split, 'archive_jobs', side_effect=ValueError('broken index')), \
                cf.ThreadPoolExecutor(2) as pool:
            with self.assertRaisesRegex(ValueError, 'broken index'): split.scan_inputs(pool, [], [], b'')

    def test_real_archive_discovery_keeps_loose_file_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / x for x in ('first.bin', 'second.bin', 'third.bin')]
            for p in paths: p.write_bytes(b'not a shader')
            files = [(str(p), p.name) for p in paths]
            big, loose = split.archive_jobs(files)
            self.assertEqual(big, []); self.assertEqual(loose, files)

    def test_main_scan_restores_worker_context_on_success_and_failure(self):
        common, trees, dictionaries = b'unity strings', {'tree': 'layout'}, {'dict': b'dictionary'}
        with mock.patch.object(split, 'COMMON', common), mock.patch.object(split, 'TREES', trees), mock.patch.object(split, 'ZDICTS', dictionaries), \
                tempfile.TemporaryDirectory() as tmp:
            mains = [(tmp, str(Path(tmp) / 'main'), '')]
            self.assertEqual(split.scan_mains(mains, bytes(128)), [('main', {}, set(), {})])
            self.assertIs(split.COMMON, common); self.assertIs(split.TREES, trees); self.assertIs(split.ZDICTS, dictionaries)
            def broken(*_):
                self.assertIsNone(split.COMMON); self.assertEqual(split.TREES, {}); self.assertEqual(split.ZDICTS, {})
                raise ValueError('damaged main')
            with mock.patch.object(split, 'scan_blob', broken):
                with self.assertRaisesRegex(ValueError, 'damaged main'): split.scan_mains(mains, bytes(128))
            self.assertIs(split.COMMON, common); self.assertIs(split.TREES, trees); self.assertIs(split.ZDICTS, dictionaries)


if __name__ == '__main__': unittest.main()
