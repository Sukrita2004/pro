"""Local key configuration checks use fake values and never access the network."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from scripts.weather import load_openweather_key


class WeatherConfigTests(unittest.TestCase):
    def test_local_file_and_environment_precedence(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'.env'
            path.write_text('# Local settings\nOTHER=value\nOPENWEATHER_API_KEY="fake-file-key"\n',encoding='utf-8-sig')
            with patch.dict(os.environ,{'OPENWEATHER_API_KEY':''}):
                self.assertEqual(load_openweather_key(path),'fake-file-key')
            with patch.dict(os.environ,{'OPENWEATHER_API_KEY':'fake-env-key'}):
                self.assertEqual(load_openweather_key(path),'fake-env-key')

    def test_missing_or_blank_key(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ,{'OPENWEATHER_API_KEY':''}):
            path=Path(folder)/'.env'
            self.assertIsNone(load_openweather_key(path))
            path.write_text('OPENWEATHER_API_KEY=\n',encoding='utf-8')
            self.assertIsNone(load_openweather_key(path))
