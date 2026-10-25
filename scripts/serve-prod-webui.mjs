import http from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = fileURLToPath(new URL("..", import.meta.url));
const dist = join(root, "dist");
const backendPort = Number(process.env.WB_BACKEND_PORT || 57891);
const publicPort = Number(process.env.WB_WEBUI_PORT || 57890);
const backend = spawn(join(root, "bin/wb-switch-darwin-arm64"), ["serve", "--no-open", "--port", String(backendPort)], {
  cwd: root,
  stdio: ["ignore", "inherit", "inherit"],
});

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};

function proxyApi(req, res) {
  const proxy = http.request(
    {
      hostname: "127.0.0.1",
      port: backendPort,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: `127.0.0.1:${backendPort}` },
    },
    (upstream) => {
      res.writeHead(upstream.statusCode || 502, upstream.headers);
      upstream.pipe(res);
    },
  );
  proxy.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end("backend unavailable");
  });
  req.pipe(proxy);
}

function serveFile(req, res) {
  const rawPath = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
  const relative = rawPath === "/" ? "index.html" : rawPath.slice(1);
  const candidate = normalize(join(dist, relative));
  const file = candidate.startsWith(`${dist}/`) && existsSync(candidate) && statSync(candidate).isFile()
    ? candidate
    : join(dist, "index.html");
  res.writeHead(200, { "content-type": contentTypes[extname(file)] || "application/octet-stream" });
  createReadStream(file).pipe(res);
}

const server = http.createServer((req, res) => {
  if (req.url?.startsWith("/api")) return proxyApi(req, res);
  return serveFile(req, res);
});

function shutdown() {
  server.close();
  backend.kill("SIGTERM");
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
backend.on("exit", (code) => {
  if (code && code !== 0) process.exitCode = code;
  server.close(() => process.exit());
});
server.listen(publicPort, "127.0.0.1", () => {
  console.log(`production webui: http://127.0.0.1:${publicPort}`);
  console.log(`backend: http://127.0.0.1:${backendPort}`);
});
