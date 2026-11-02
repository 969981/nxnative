"""The opt-in pulse guard must reject changed shader shapes instead of patching unrelated math."""
import ast
from pathlib import Path
import re
import unittest
from typing import Any

TOOLS = Path(__file__).resolve().parents[2] / 'gfx/tools'
tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
nodes: list[ast.stmt] = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'zero_period_guard']
namespace: dict[str, Any] = {'re': re}
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), namespace)
guard = namespace['zero_period_guard']

MSL = '''
    float reciprocal = 1.0 / (*spvDescriptorSet0.vp_c4)._m0[9].w;
    float phase = reciprocal * time;
    float wave = cos(phase);
    float pulse = wave * (*spvDescriptorSet0.vp_c4)._m0[10].x;
    out.color = fma(pulse, color, color);
'''


class ZeroPeriodGuard(unittest.TestCase):
    def test_profile_fields_and_renumbered_variables(self):
        source = MSL.replace('vp_c4', 'vp_c7').replace('[9].w', '[13].y').replace('[10].x', '[14].z')
        result = guard(source, '7:13.y:14.z')
        self.assertIn('float dm_pulse_period = (*spvDescriptorSet0.vp_c7)._m0[13].y;', result)
        self.assertIn('float reciprocal = dm_pulse_period == 0.0 ? 0.0 : 1.0 / dm_pulse_period;', result)
        self.assertIn('float pulse = dm_pulse_period == 0.0 ? 0.0 : wave * (*spvDescriptorSet0.vp_c7)._m0[14].z;', result)
        self.assertIn('out.color = fma(pulse, color, color);', result)

    def test_changed_or_ambiguous_shader_fails(self):
        for source in (MSL.replace('1.0 / ', '2.0 / '), MSL.replace('wave * ', 'wave + '), MSL + MSL):
            with self.subTest(source=source), self.assertRaises(ValueError):
                guard(source, '4:9.w:10.x')

    def test_invalid_profile_fields_fail(self):
        for spec in ('4:9.q:10.x', '4:9.w', '4:9.w:10.x:extra', '4:-1.w:10.x'):
            with self.subTest(spec=spec), self.assertRaises(ValueError):
                guard(MSL, spec)


if __name__ == '__main__':
    unittest.main()
