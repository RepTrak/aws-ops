import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import fs from 'fs'

// Serve ../snapshots/* at /snapshots/* so the app can read snapshot data
// in dev without needing to copy files.
function snapshotsMiddleware() {
  const snapshotsRoot = path.resolve(__dirname, '..', 'snapshots')
  return {
    name: 'serve-snapshots',
    configureServer(server: any) {
      server.middlewares.use('/snapshots', (req: any, res: any, next: any) => {
        const url = (req.url || '/') as string

        // /_list — return all snapshot folder names, newest first
        if (url === '/_list' || url === '/_list/') {
          try {
            const folders = fs.readdirSync(snapshotsRoot)
              .filter(e => {
                try { return fs.statSync(path.join(snapshotsRoot, e)).isDirectory() && /^\d{4}/.test(e) }
                catch { return false }
              })
              .sort()
              .reverse()
            res.setHeader('Content-Type', 'application/json')
            res.end(JSON.stringify(folders))
          } catch {
            res.setHeader('Content-Type', 'application/json')
            res.end('[]')
          }
          return
        }

        // Serve any other snapshot file
        const rel = url.replace(/\.\./g, '')
        const filePath = path.join(snapshotsRoot, rel)
        if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
          const ct = path.extname(filePath) === '.json' ? 'application/json' : 'application/octet-stream'
          res.setHeader('Content-Type', ct)
          res.end(fs.readFileSync(filePath))
        } else {
          next()
        }
      })
    },
  }
}

export default defineConfig({
  plugins: [react(), snapshotsMiddleware()],
  base: './',
  resolve: { alias: { '@': path.resolve(__dirname, './src') } },
  build: { outDir: 'dist', sourcemap: false },
})
