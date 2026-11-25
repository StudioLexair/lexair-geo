import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    environment: 'node',
    testTimeout: 20000,
    hookTimeout: 60000,
    fileParallelism: false,
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/cli/**', 'src/index.ts'],
      reporter: ['text-summary', 'lcov', 'json-summary'],
    },
  },
});
