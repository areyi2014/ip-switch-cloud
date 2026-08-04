/**
 * Local config server — serves UI files and handles config save/load.
 *
 * POST /api/save-config  { profile: {...} }  → merges into config.json
 * GET  /api/config                            → returns current config.json
 * GET  /                                      → serves static files from ui/
 *
 * Config file: ~/.cloud-ip-rotator/config.json
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = 8787;
const UI_DIR = __dirname;
const CONFIG_DIR = path.join(os.homedir(), '.cloud-ip-rotator');
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function loadConfig() {
  try {
    if (!fs.existsSync(CONFIG_FILE)) return { cloudflare: null, profiles: {} };
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
  } catch {
    return { cloudflare: null, profiles: {} };
  }
}

function saveConfig(config) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), 'utf-8');
}

function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

const server = http.createServer((req, res) => {
  setCors(res);

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // API: save config
  if (req.method === 'POST' && req.url === '/api/save-config') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const config = loadConfig();

        // Save profile
        if (data.profile) {
          const p = data.profile;
          config.profiles[p.name] = p;
        }

        // Save global cloudflare (if provided separately)
        if (data.cloudflare) {
          config.cloudflare = data.cloudflare;
        }

        saveConfig(config);

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          success: true,
          message: 'Configuration saved to ' + CONFIG_FILE,
          path: CONFIG_FILE,
          profileCount: Object.keys(config.profiles).length,
        }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, error: err.message }));
      }
    });
    return;
  }

  // API: get config
  if (req.method === 'GET' && req.url === '/api/config') {
    const config = loadConfig();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(config));
    return;
  }

  // API: delete profile
  if (req.method === 'POST' && req.url === '/api/delete-profile') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const { name } = JSON.parse(body);
        const config = loadConfig();
        if (name in config.profiles) {
          delete config.profiles[name];
          saveConfig(config);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true, message: 'Profile deleted: ' + name }));
        } else {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: false, error: 'Profile not found: ' + name }));
        }
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, error: err.message }));
      }
    });
    return;
  }

  // Static file serving
  let filePath = req.url === '/' ? '/config-form.html' : req.url;
  // Strip query string
  filePath = filePath.split('?')[0];
  // Prevent path traversal
  filePath = path.normalize(filePath).replace(/^(\.\.[\/\\])+/, '');
  const fullPath = path.join(UI_DIR, filePath);

  if (!fullPath.startsWith(UI_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  const ext = path.extname(fullPath);
  const contentType = MIME[ext] || 'application/octet-stream';

  fs.readFile(fullPath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found: ' + filePath);
      return;
    }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Config server running at http://localhost:${PORT}`);
  console.log(`Config file: ${CONFIG_FILE}`);
});
