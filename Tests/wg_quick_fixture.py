"""Load the unmodified, commit-pinned upstream fixture without a build cache."""
import hashlib
import json
from pathlib import Path


def load_source():
    root = Path(__file__).resolve().parent.parent
    fixture = root / 'Tests/Fixtures/wg-quick-darwin.bash'
    metadata = json.loads(fixture.with_name('wg-quick-source.json').read_text())
    versions = dict(line.split('=', 1) for line in
                    (root / 'Scripts/wireguard-versions.env').read_text().splitlines()
                    if line and not line.startswith('#'))
    if metadata['revision'] != versions['WIREGUARD_TOOLS_COMMIT']:
        raise RuntimeError('Update the wg-quick test fixture to match the pinned tools revision')
    source = fixture.read_bytes()
    if hashlib.sha256(source).hexdigest() != metadata['sha256']:
        raise RuntimeError('The wg-quick test fixture failed its source hash check')
    return source.decode('utf-8')
