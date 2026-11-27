"""Diagnostica importaciones PE del PostGIS instalado, sin mostrar datos de usuarios."""
import os
import sys
from pathlib import Path
import pefile

root = Path(sys.argv[1])
locations = [root / 'servidor' / 'pg' / 'bin', root / 'servidor' / 'pg' / 'lib',
             Path(os.environ['SystemRoot']) / 'System32']
indices = [{p.name.lower(): p for p in d.glob('*') if p.is_file()} for d in locations]
queue = [root / 'servidor' / 'pg' / 'lib' / 'postgis-3.dll']
visited = set()
missing = set()
while queue:
    file = queue.pop()
    if file.name.lower() in visited:
        continue
    visited.add(file.name.lower())
    try:
        pe = pefile.PE(str(file), fast_load=True)
        pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
                                               pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT']])
        imports = list(getattr(pe, 'DIRECTORY_ENTRY_IMPORT', [])) + list(getattr(pe, 'DIRECTORY_ENTRY_DELAY_IMPORT', []))
        for entry in imports:
            name = entry.dll.decode('ascii', 'replace').lower()
            if name.startswith(('api-ms-win-', 'ext-ms-win-')) or name == 'postgres.exe':
                continue
            found = next((index[name] for index in indices if name in index), None)
            if found is None:
                missing.add(name)
                print(f'MISSING {file.name} -> {name}', flush=True)
            elif found.parent != locations[-1] and name not in visited:
                queue.append(found)
    except (OSError, pefile.PEFormatError) as exc:
        print(f'No se pudo inspeccionar {file.name}: {exc}', flush=True)
print(f'Archivos propios analizados: {len(visited)}', flush=True)
print('Dependencias ausentes detectadas: ' + (', '.join(sorted(missing)) or 'ninguna en importaciones PE'), flush=True)
