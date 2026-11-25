import { readFile, stat } from 'node:fs/promises';
import { z } from 'zod';

/** Manifiesto del paquete cartográfico instalado (scripts/maps/build_package.sh). */
export const MapManifest = z.object({
  name: z.string(),
  version: z.string(),
  generatedAt: z.string(),
  isSynthetic: z.boolean(),
  source: z.object({
    name: z.string(),
    url: z.string().optional(),
    timestamp: z.string().nullable().optional(),
    sha256: z.string().optional(),
  }),
  attribution: z.string(),
  license: z.string(),
  bounds: z.tuple([z.number(), z.number(), z.number(), z.number()]),
  center: z.tuple([z.number(), z.number()]).optional(),
  minzoom: z.number().int(),
  maxzoom: z.number().int(),
  styles: z.array(
    z.object({
      id: z.string().regex(/^[a-z0-9_]+$/),
      name: z.string(),
      file: z.string(),
      sha256: z.string().optional(),
      kind: z.enum(['standard', 'dark', 'high_contrast', 'topographic', 'satellite']),
    }),
  ),
  missingFeatures: z.array(z.string()).default([]),
});
export type MapManifest = z.infer<typeof MapManifest>;

let cached: { mtimeMs: number; manifest: MapManifest } | null = null;

export async function readManifest(path: string): Promise<MapManifest | null> {
  try {
    const st = await stat(path);
    if (cached && cached.mtimeMs === st.mtimeMs) return cached.manifest;
    const manifest = MapManifest.parse(JSON.parse(await readFile(path, 'utf8')));
    cached = { mtimeMs: st.mtimeMs, manifest };
    return manifest;
  } catch {
    return null;
  }
}
