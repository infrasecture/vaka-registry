import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

const codexHome = process.env.CODEX_HOME;
if (!codexHome) {
  throw new Error("CODEX_HOME is required");
}

const socketPath =
  process.env.CODEX_ACP_SOCKET ?? path.join(codexHome, "run", "codex-acp.sock");
const adapterPath = "/opt/codex-acp/node_modules/.bin/codex-acp";
const clients = new Set();
let stopping = false;

fs.mkdirSync(path.dirname(socketPath), { recursive: true, mode: 0o700 });
try {
  const existing = fs.lstatSync(socketPath);
  if (!existing.isSocket()) {
    throw new Error(`refusing to replace non-socket path: ${socketPath}`);
  }
  fs.unlinkSync(socketPath);
} catch (error) {
  if (error?.code !== "ENOENT") {
    throw error;
  }
}

const server = net.createServer({ allowHalfOpen: true }, (socket) => {
  if (stopping) {
    socket.destroy();
    return;
  }

  socket.setNoDelay(true);
  const child = spawn(adapterPath, [], {
    cwd: process.env.MYCODEX_WORKDIR ?? process.cwd(),
    env: process.env,
    stdio: ["pipe", "pipe", "inherit"],
  });
  const client = { socket, child };
  clients.add(client);

  socket.pipe(child.stdin);
  child.stdout.pipe(socket);
  child.stdin.on("error", (error) => {
    if (error.code !== "EPIPE") {
      console.error(`codex-acp stdin error: ${error.message}`);
    }
    socket.destroy();
  });

  const stopChild = () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
    }
  };

  socket.on("error", (error) => {
    console.error(`codex-acp broker client error: ${error.message}`);
    stopChild();
  });
  socket.on("close", stopChild);

  child.on("error", (error) => {
    console.error(`codex-acp broker spawn error: ${error.message}`);
    socket.destroy(error);
  });
  child.on("exit", (code, signal) => {
    clients.delete(client);
    if (!socket.destroyed) {
      socket.end();
    }
    if (code && !stopping) {
      console.error(`codex-acp exited with status ${code}${signal ? ` (${signal})` : ""}`);
    }
  });
});

server.on("error", (error) => {
  console.error(`codex-acp broker error: ${error.message}`);
  process.exitCode = 1;
});

server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
  console.error(`codex-acp broker ready on ${socketPath}`);
});

function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  server.close();
  for (const { socket, child } of clients) {
    socket.destroy();
    child.kill("SIGTERM");
  }
  try {
    fs.unlinkSync(socketPath);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      console.error(`cannot remove ACP socket: ${error.message}`);
    }
  }
  if (signal) process.kill(process.pid, signal);
}

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
process.once("exit", () => shutdown());
