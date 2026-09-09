"""Exercise the converter in an isolated checkout with synthetic upstream configs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


CONVERTER = Path(__file__).resolve().parents[1] / 'scripts' / 'convert.lua'


class ConvertTest(unittest.TestCase):
    def convert(self, sources):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copyfile(CONVERTER, root / 'scripts' / 'convert.lua')
            source = root / 'upstream' / 'lsp'
            source.mkdir(parents=True)
            for name, content in sources.items():
                (source / f'{name}.lua').write_text(content)
            env = dict(os.environ, NVIM_LSPCONFIG=str(source.parent))
            env.pop('NVIM_LISTEN_ADDRESS', None)
            result = subprocess.run(
                ['nvim', '--headless', '-l', str(root / 'scripts' / 'convert.lua')],
                env=env, capture_output=True, text=True, timeout=30, check=True,
            )
            documents = {
                path.stem: path.read_text() for path in (root / 'lsp').glob('*.toml')
            }
            configs = {
                name: tomllib.loads(doc)['languageServers'][name]
                for name, doc in documents.items()
            }
            return configs, documents, result.stdout + result.stderr

    def test_report_lists_every_server_without_a_generated_command(self):
        configs, _, report = self.convert({
            'missing': 'return {}',
            'empty': 'return {cmd = {}}',
            'dynamic': "return {cmd = function() error('must not execute') end}",
            'broken': "error('cannot load config')",
            'static': "return {cmd = {'server', '--stdio'}}",
            'tsc': 'return {cmd = function() end}',
        })
        self.assertIn('files_without_cmd=4\n', report)
        self.assertIn('--- MISSING CMD ---\nbroken\ndynamic\nempty\nmissing\n', report)
        self.assertEqual(configs['static']['cmd'], ['server', '--stdio'])
        for name in ('missing', 'empty', 'dynamic', 'broken'):
            self.assertNotIn('cmd', configs[name])

    def test_svelte_uses_global_stdio_command(self):
        configs, documents, _ = self.convert({
            'svelte': "return {cmd = function() error('must not execute') end}",
        })
        self.assertEqual(configs['svelte']['cmd'], ['svelteserver', '--stdio'])
        self.assertIn('node_modules/.bin', documents['svelte'])

    def test_tsc_uses_native_compiler_without_executing_dynamic_command(self):
        configs, documents, _ = self.convert({
            'tsc': "return {cmd = function() error('must not execute') end, filetypes = {'typescript'}}",
        })
        self.assertEqual(configs['tsc']['cmd'], ['tsc', '--lsp', '--stdio'])
        self.assertIn('TypeScript 7.0+', documents['tsc'])
        self.assertIn('tsgo', documents['tsc'])


if __name__ == '__main__':
    unittest.main()
