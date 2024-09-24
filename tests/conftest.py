import os
from os.path import dirname, join as path_join
import sys

import pytest


FIXTURES = path_join(dirname(__file__), 'fixtures')
BASE = dirname(dirname(__file__))
sys.path.insert(0, path_join(BASE, 'build'))

for name in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SECURITY_TOKEN', 'AWS_SESSION_TOKEN']:
    os.environ[name] = 'testing'


class LambdaContext:
    def __init__(self):
        self.function_name = 'test-replicate'

    def get_remaining_time_in_millis(self):
        return 60000
