// A stand-in transcription endpoint for the app-level check.
//
// It writes down what it received rather than only what it replied, because
// the interesting failures are on the request side: a WAV header that is
// well-formed enough to post but wrong, or an Authorization header that never
// got set. Reading those off the transcript alone is impossible.
//
// Usage: node server.mjs <port> <reply-file> <request-dump>

import http from "node:http";
import fs from "node:fs";

const [port, replyFile, dumpFile] = process.argv.slice(2);
const reply = JSON.parse(fs.readFileSync(replyFile, "utf8"));

http
  .createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks);
      const record = {
        method: request.method,
        url: request.url,
        contentType: request.headers["content-type"] ?? null,
        authorization: request.headers["authorization"] ?? null,
        bodyBytes: body.length,
        // The contract the app is held to, checked here rather than trusted.
        wav: inspect(body),
      };
      fs.writeFileSync(dumpFile, JSON.stringify(record, null, 2));
      response.writeHead(reply.status ?? 200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(reply.body ?? { text: "" }));
    });
  })
  .listen(Number(port), "127.0.0.1", () => {
    console.log(`listening on ${port}`);
  });

// Pull the base64 audio out of the JSON body and read the WAV header off it.
function inspect(body) {
  let parsed;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch {
    return { error: "body was not JSON" };
  }
  if (typeof parsed.audio !== "string") {
    return { error: "no audio field", keys: Object.keys(parsed) };
  }
  const audio = Buffer.from(parsed.audio, "base64");
  if (audio.length < 44) return { error: "audio shorter than a header" };
  const header = {
    riff: audio.toString("ascii", 0, 4),
    wave: audio.toString("ascii", 8, 12),
    fmt: audio.toString("ascii", 12, 16),
    declaredRiffSize: audio.readUInt32LE(4),
    actualRiffSize: audio.length - 8,
    formatTag: audio.readUInt16LE(20),
    channels: audio.readUInt16LE(22),
    sampleRate: audio.readUInt32LE(24),
    byteRate: audio.readUInt32LE(28),
    blockAlign: audio.readUInt16LE(32),
    bitsPerSample: audio.readUInt16LE(34),
    data: audio.toString("ascii", 36, 40),
    declaredDataSize: audio.readUInt32LE(40),
    actualDataBytes: audio.length - 44,
    language: parsed.language ?? null,
  };
  header.consistent =
    header.riff === "RIFF" &&
    header.wave === "WAVE" &&
    header.fmt === "fmt " &&
    header.data === "data" &&
    header.declaredRiffSize === header.actualRiffSize &&
    header.declaredDataSize === header.actualDataBytes &&
    header.formatTag === 1 &&
    header.byteRate === header.sampleRate * header.channels * (header.bitsPerSample / 8);
  return header;
}