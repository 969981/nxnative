"""The launcher bridge and machine-readable roster, each run in a fresh host process."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOST = Path(__file__).resolve().parents[2] / 'host'
LEGACY = '53574e415449564578626c0000000001'
SECOND = '000000000000000000000000000000ab'
ALICE = {'id': LEGACY, 'nickname': 'Alice'}
BOB = {'id': SECOND, 'nickname': 'Bob'}


@unittest.skipUnless(sys.platform == 'darwin', 'Apple host library')
class LocalUsers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        cls.root = Path(tmp.name)
        probe = cls.root / 'probe.c'
        probe.write_text('''
#include "local_users.h"
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (dm_users_error()) { fprintf(stderr, "%s", dm_users_error()); return 2; }
    if (argc == 2 && !strcmp(argv[1], "pick")) {
        if (dm_users_selection_locked() || !dm_users_select_index(1)) return 3;
        if (strcmp(getenv("DM_USER_ID"), dm_selected_user()->id)) return 4;
        if (!dm_users_begin_session() || dm_users_select_index(0)) return 5;
    }
    if (argc == 2 && !strcmp(argv[1], "locked")) {
        if (!dm_users_selection_locked() || dm_users_select_index(0)) return 6;
    }
    return dm_users_write_json(stdout) ? 0 : 1;
}
''')
        cls.exe = cls.root / 'probe'
        subprocess.run(['clang', '-Wall', '-Werror', '-fobjc-arc', '-I', HOST, probe,
                        HOST / 'local_users.m', '-framework', 'Foundation', '-o', cls.exe], check=True)

    def query(self, roster=None, *, selected=None, action=None, raw=None, path=None, nick=None):
        env = {k: v for k, v in os.environ.items() if k not in ('DM_USERS_FILE', 'DM_USER_ID', 'DM_NICK')}
        if roster is not None or raw is not None:
            path = self.root / 'users.json'
            path.write_bytes(json.dumps(roster).encode() if raw is None else raw)
        if path is not None:
            env['DM_USERS_FILE'] = str(path)
        if selected is not None:
            env['DM_USER_ID'] = selected
        if nick is not None:
            env['DM_NICK'] = nick
        return subprocess.run([self.exe] + ([action] if action else []), env=env, capture_output=True, timeout=5)

    def test_default_and_legacy_nickname(self):
        self.assertEqual(json.loads(self.query().stdout),
                         {'version': 1, 'users': [dict(ALICE, nickname='Player')], 'selected': LEGACY})
        self.assertEqual(json.loads(self.query(nick='Player One').stdout)['users'][0]['nickname'], 'Player One')

    def test_external_and_launcher_selection(self):
        roster = {'version': 1, 'users': [ALICE, dict(BOB, id=SECOND.upper())]}
        for selected, action, expected in [(None, None, LEGACY), (SECOND, 'locked', SECOND), (None, 'pick', SECOND)]:
            with self.subTest(action=action):
                result = self.query(roster, selected=selected, action=action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {'version': 1, 'users': [ALICE, BOB], 'selected': expected})

    def test_invalid_configuration_does_not_select_someone_else(self):
        for roster in [[], {'version': True, 'users': [ALICE]}, {'version': 2, 'users': [ALICE]},
                       {'version': 1, 'users': []}, {'version': 1, 'users': [BOB, dict(BOB, id=SECOND.upper())]},
                       {'version': 1, 'users': [dict(BOB, id='0' * 32)]}, {'version': 1, 'users': [dict(BOB, id='../evil')]},
                       {'version': 1, 'users': [dict(BOB, nickname='x\0y')]},
                       {'version': 1, 'users': [dict(BOB, nickname='\u00e9' * 17)]},
                       {'version': 1, 'users': [dict(BOB, id=f'{i + 1:032x}') for i in range(9)]}]:
            with self.subTest(roster=roster):
                result = self.query(roster)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr)
                self.assertFalse(result.stdout)
        self.assertNotEqual(self.query({'version': 1, 'users': [ALICE]}, selected=SECOND).returncode, 0)
        self.assertNotEqual(self.query(raw=b'{').returncode, 0)
        self.assertNotEqual(self.query(path=self.root / 'missing').returncode, 0)
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        self.assertNotEqual(self.query(path=fifo).returncode, 0)
