"""Build web audio sprites from a local thock-soundpacks checkout. Requires ffmpeg.

Usage: python3 scripts/import-soundpacks.py /path/to/thock-soundpacks
Only the reviewed Cherry MX / mechvibes and tplai / kbsim MIT packs are included.
"""
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import wave
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KEYS = {
    'default': 'default', 'tab': 'Tab', 'space': 'Space', 'del': 'Backspace',
    'backspace': 'Backspace', 'esc': 'Escape', 'capsLock': 'CapsLock',
    'ctrlLeft': 'ControlLeft', 'enter': 'Enter', 'shiftLeft': 'ShiftLeft',
    'shiftRight': 'ShiftRight', 'optionLeft': 'AltLeft', 'optionRight': 'AltRight',
    'arrLeft': 'ArrowLeft', 'arrRight': 'ArrowRight', 'arrUp': 'ArrowUp',
    'arrDown': 'ArrowDown', 'home': 'Home', 'end': 'End', 'pgUp': 'PageUp',
    'pgDn': 'PageDown', 'clear': 'NumLock', 'fn': 'Fn', '*': 'NumpadMultiply',
    '/': 'Slash', '+': 'NumpadAdd', '-': 'Minus', '=': 'Equal', '[': 'BracketLeft',
    ']': 'BracketRight', ';': 'Semicolon', "'": 'Quote', ',': 'Comma',
    '.': 'Period', '\\': 'Backslash', '`': 'Backquote',
}
CHARACTER = {
    'black': ('Linear', 'Dense. Smooth. Understated.', '#48484a'),
    'blue': ('Clicky', 'A bright, unmistakable click.', '#427699'),
    'brown': ('Tactile', 'A softer click with a rounded body.', '#956c49'),
    'red': ('Linear', 'Light, clean, and quick.', '#b65449'),
    'Holy Panda': ('Tactile', 'A full, rounded thock.', '#9b8565'),
    'Alpaca': ('Linear', 'Soft edges. A smooth landing.', '#b88592'),
    'Ink Black': ('Linear', 'Low, rich, and weighted.', '#48484a'),
    'Ink Red': ('Linear', 'A lighter, livelier note.', '#b65449'),
    'Turquoise Tealios': ('Linear', 'A clean, glassy tap.', '#4d9697'),
    'Box Navy': ('Clicky', 'Bold, sharp, and unapologetic.', '#455e7d'),
    'Cream': ('Linear', 'Dry, warm, and woody.', '#a7946a'),
    'SKCM Blue': ('Clicky', 'A crisp click with a vintage edge.', '#427699'),
    'Buckling Spring': ('Clicky', 'The unmistakable sound of a classic.', '#767677'),
    'Unknown': ('Tactile', 'A rounded, rubber-dome thock.', '#8b7394'),
}


def import_packs(source: Path):
    registry = json.loads((source / 'manifest.json').read_text())
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    output = ROOT / 'packages/soundpacks/sounds'
    output.mkdir(parents=True, exist_ok=True)
    catalog = []
    for pack in registry['soundpacks']['keyboard']:
        meta = pack['metadata']
        if not (meta['author'] == 'tplai' or meta['brand'] == 'Cherry MX'):
            continue
        assert pack['license']['type'] == 'MIT'
        slug = re.sub(r'[^a-z0-9]+', '-', f"{meta['brand']}-{meta['name']}".lower()).strip('-')
        key = meta['name'].split()[0].lower() if meta['brand'] == 'Cherry MX' else meta['name']
        kind, description, color = CHARACTER[key]
        with zipfile.ZipFile(source / pack['content']['path'] / (pack['id'] + '.zip')) as archive, tempfile.TemporaryDirectory() as temp:
            config = json.loads(archive.read('config.json'))
            files = sorted({name for entry in config['sounds'].values() for names in entry.values() for name in names})
            sprites, frame = {}, 0
            path = Path(temp) / 'sprite.wav'
            with wave.open(str(path), 'wb') as combined:
                expected = None
                for name in files:
                    with wave.open(io.BytesIO(archive.read(name))) as sample:
                        params = (sample.getnchannels(), sample.getsampwidth(), sample.getframerate())
                        assert params[1:] == (2, 44100)
                        if expected is None:
                            expected = params
                            combined.setnchannels(params[0]); combined.setsampwidth(2); combined.setframerate(44100)
                        assert expected == params
                        frames = sample.getnframes()
                        sprites[name] = [round(frame / 44.1, 4), round(frames / 44.1, 4)]
                        combined.writeframes(sample.readframes(frames))
                        padding = 2205
                        combined.writeframes(b'\0' * padding * params[0] * 2)
                        frame += frames + padding
            for ext, codec in [('ogg', ['-c:a', 'libvorbis', '-q:a', '7']), ('mp3', ['-c:a', 'libmp3lame', '-q:a', '2'])]:
                subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(path), *codec, str(output / f'{slug}.{ext}')], check=True)
            sounds = {}
            for name, events in config['sounds'].items():
                if name == 'command':
                    codes = ['MetaLeft', 'MetaRight']
                elif name in KEYS:
                    codes = [KEYS[name]]
                elif re.fullmatch('[a-z]', name):
                    codes = ['Key' + name.upper()]
                elif re.fullmatch('[0-9]', name):
                    codes = ['Digit' + name]
                elif re.fullmatch('f[0-9]+', name):
                    codes = [name.upper()]
                else:
                    raise ValueError(f'Unmapped key: {name}')
                for code in codes:
                    sounds[code] = {'down': events.get('down', []), 'up': events.get('up', [])}
            if 'ControlLeft' in sounds:
                sounds['ControlRight'] = sounds['ControlLeft']
            catalog.append({
                'id': slug, 'sourceId': pack['id'], 'name': meta['name'], 'brand': meta['brand'], 'kind': kind,
                'description': description, 'color': color, 'author': meta['author'],
                'supportsKeyUp': meta['supportsKeyUp'], 'sampleCount': len(files),
                'source': f"https://github.com/kamillobinski/thock-soundpacks/tree/{revision}/{pack['content']['path']}",
                'license': pack['license'], 'sprite': sprites, 'sounds': sounds,
            })
            print(slug, len(files), 'samples')
    assert len(catalog) == 18
    (ROOT / 'packages/soundpacks/catalog.json').write_text(json.dumps(catalog, separators=(',', ':')) + '\n')
    print('Built 18 packs,', sum(p.stat().st_size for p in output.iterdir() if p.suffix in ('.mp3', '.ogg')), 'audio bytes')


if __name__ == '__main__':
    import_packs(Path(sys.argv[1]))
