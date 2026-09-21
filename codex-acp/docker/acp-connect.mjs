import net from "node:net";
import path from "node:path";
import process from "node:process";

const codexHome = process.env.CODEX_HOME;
if (!codexHome) {
  console.error("codex-acp connector: CODEX_HOME is required");
  process.exit(2);
}

const socketPath =
  process.env.CODEX_ACP_SOCKET ?? path.join(codexHome, "run", "codex-acp.sock");
const deadline = Date.now() + Number(process.env.CODEX_ACP_CONNECT_TIMEOUT_MS ?? 10000);
let socket;

function connect() {
  const candidate = net.createConnection({ path: socketPath, allowHalfOpen: true });
  let connected = false;
  socket = candidate;
  candidate.once("connect", () => {
    connected = true;
    candidate.setNoDelay(true);
    process.stdin.pipe(candidate);
    candidate.pipe(process.stdout);
  });
  candidate.once("error", (error) => {
    candidate.destroy();
    if ((error.code === "ENOENT" || error.code === "ECONNREFUSED") && Date.now() < deadline) {
      setTimeout(connect, 100);
      return;
    }
    console.error(`codex-acp connector: ${error.message}`);
    process.exitCode = 1;
  });
  candidate.once("close", () => {
    if (connected && !process.stdin.readableEnded) {
      process.stdin.unpipe(candidate);
      process.stdin.pause();
    }
  });
}

process.stdin.on("error", (error) => {
  console.error(`codex-acp connector stdin: ${error.message}`);
  socket?.destroy();
  process.exitCode = 1;
});
process.stdout.on("error", (error) => {
  if (error.code !== "EPIPE") {
    console.error(`codex-acp connector stdout: ${error.message}`);
    process.exitCode = 1;
  }
  socket?.destroy();
});

connect();
