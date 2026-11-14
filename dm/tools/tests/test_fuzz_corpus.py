"""The fuzz harnesses' regression corpus (dm/tools/fuzz/corpus/<parser>/, synthetic inputs only): every input a harness found a finding with is replayed on each tool-test run,
so a fixed parser stays fixed. Inputs of findings still open (dm/tools/fuzz/known.tsv) are expected failures: once the parser is fixed the test reports an unexpected success,
and the row comes out of known.tsv. The harnesses' seeds must parse cleanly, so the seeds and the parsers stay in step. No game files needed."""
import importlib
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
FUZZ = REPO / 'dm/tools/fuzz'
sys.path.insert(0, str(FUZZ))
import fuzzlib

HARNESSES = sorted(p.stem.removeprefix('fuzz_') for p in FUZZ.glob('fuzz_*.py'))
OPEN = {h: {n for names in fuzzlib.known(h).values() for n in names} for h in HARNESSES}


def harness(h): return importlib.import_module('fuzz_' + h)


def replay(test, h, data):
    try: fuzzlib.replay(h, harness(h).check, data)
    except fuzzlib.Finding as f: test.fail(f'{h}: {f.signature}\n{f.text}')


class Corpus(unittest.TestCase):
    def test_seeds_parse_cleanly(self):
        for h in HARNESSES:
            for name, data in harness(h).seeds().items():
                with self.subTest(harness=h, seed=name): replay(self, h, data)

    def test_known_rows_name_corpus_inputs(self):
        rows = [line.split('\t') for line in fuzzlib.KNOWN.read_text().splitlines() if line.strip() and not line.startswith('#')]
        for row in rows:
            with self.subTest(row=row[:3]):
                self.assertEqual(len(row), 5, 'harness, signature pattern, corpus files, issue, what')
                self.assertIn(row[0], HARNESSES)
                for name in row[2].split(','): self.assertTrue((fuzzlib.CORPUS / row[0] / name).is_file(), f'corpus/{row[0]}/{name}')
        self.assertEqual({p.name for p in fuzzlib.CORPUS.iterdir() if p.is_dir()} - set(HARNESSES), set(), 'a corpus folder without a harness')




class Pacx403Bounds(unittest.TestCase):
    """Malformed PACx 403 root chunk tables must use the declared [RED] rejection."""

    def test_truncated_chunk_table_does_not_raise_struct_error(self):
        import struct
        data = bytearray(0x36)
        data[:8] = b'PACx403L'
        struct.pack_into('<III', data, 0x10, len(data), 0, 0)
        struct.pack_into('<II', data, 0x20, 0, 20)  # claims a larger table than the file has
        struct.pack_into('<I', data, 0x30, 2)
        with self.assertRaises(SystemExit) as err:
            harness('shader_split').ss.scan_blob(bytes(data), '/truncated-pacx', [])
        self.assertIn('PACx 403 root chunk table', str(err.exception))
        self.assertTrue(str(err.exception).startswith('[RED] '))


def add(h, path):
    def test(self): replay(self, h, path.read_bytes())
    if path.name in OPEN[h]: test = unittest.expectedFailure(test)   # an open finding (known.tsv): fails until the parser is fixed
    setattr(Corpus, f'test_{h}_{path.name.replace(".", "_").replace("-", "_")}', test)


for _h in HARNESSES:
    if (fuzzlib.CORPUS / _h).is_dir():
        for _p in sorted((fuzzlib.CORPUS / _h).iterdir()): add(_h, _p)


if __name__ == '__main__':
    unittest.main()
