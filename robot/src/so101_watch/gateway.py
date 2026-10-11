"""WSS gateway (SPEC §10.1): auth, a single controlling client, schema validation, heartbeat.

The gateway owns the asyncio loop and runs the control loop as a task on it, so
message handling and ticks share one thread and never race on agent state.
The control loop never awaits the network: outbound messages go into a bounded
per-client queue that a separate writer task drains.
"""

from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import logging
import os
import ssl
import time
from collections.abc import Callable
from http import HTTPStatus

from websockets.asyncio.server import Server, ServerConnection, serve
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Request, Response

from .agent import RobotAgent
from .protocol import PROTOCOL_VERSION, HapticEvent, ProtocolError, to_dict

log = logging.getLogger(__name__)

MAX_MESSAGE_BYTES = 64 * 1024
OUTBOX_LIMIT = 256


class Outbox:
    """Haptic sink handed to RobotAgent; the gateway drains it after every tick/message."""

    def __init__(self) -> None:
        self._items: list[HapticEvent] = []

    def __call__(self, ev: HapticEvent) -> None:
        self._items.append(ev)

    def drain(self) -> list[dict]:
        items, self._items = self._items, []
        return [to_dict(e) for e in items]


class Gateway:
    def __init__(self, agent: RobotAgent, outbox: Outbox, token: str,
                 clock: Callable[[], float] = time.monotonic) -> None:
        if len(token) < 16:
            raise ValueError("token must be at least 16 characters")
        self.agent = agent
        self.outbox = outbox
        self.clock = clock
        self._expected_auth = f"Bearer {token}".encode()
        self._client: ServerConnection | None = None
        self._queue: asyncio.Queue[str] | None = None
        self._loop_task: asyncio.Task | None = None
        self.tick_errors = 0

    # ------------------------------------------------------------ connection handling

    def _process_request(self, conn: ServerConnection, request: Request) -> Response | None:
        auth = request.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(auth, self._expected_auth):
            return conn.respond(HTTPStatus.UNAUTHORIZED, "unauthorized\n")
        if self._client is not None:
            return conn.respond(HTTPStatus.CONFLICT, "another controller is connected\n")
        return None

    async def _handler(self, conn: ServerConnection) -> None:
        if self._client is not None:  # lost the race against another handshake
            await conn.close(4409, "busy")
            return
        self._client = conn
        self._queue = asyncio.Queue(maxsize=OUTBOX_LIMIT)
        writer = asyncio.create_task(self._writer(conn, self._queue))
        self._enqueue(self.agent.status())
        try:
            async for raw in conn:
                self._on_raw(raw)
        except ConnectionClosed:
            pass
        finally:
            self._client = None
            self._queue = None
            writer.cancel()
            self.agent.client_disconnected(self.clock())
            self._flush()

    def _on_raw(self, raw: str | bytes) -> None:
        try:
            reply = self.agent.handle_message(json.loads(raw), self.clock())
        except (json.JSONDecodeError, UnicodeDecodeError, ProtocolError) as e:
            reply = {"protocol_version": PROTOCOL_VERSION, "type": "error", "reason": str(e)}
        if reply is not None:
            self._enqueue(reply)
        self._flush()

    def _enqueue(self, msg: dict) -> None:
        q = self._queue
        if q is None:
            return
        if q.full():  # slow client: drop the oldest rather than stall the control loop
            q.get_nowait()
        q.put_nowait(json.dumps(msg, ensure_ascii=False))

    def _flush(self) -> None:
        for msg in self.agent.drain_status() + self.outbox.drain():
            self._enqueue(msg)

    @staticmethod
    async def _writer(conn: ServerConnection, q: asyncio.Queue[str]) -> None:
        try:
            while True:
                await conn.send(await q.get())
        except ConnectionClosed:
            pass

    # ------------------------------------------------------------ control loop

    async def _control_loop(self) -> None:
        period = 1.0 / self.agent.cfg.control_hz
        next_t = self.clock()
        while True:
            try:
                self.agent.tick(self.clock())
            except Exception:  # noqa: BLE001 - keep holding and report, never die silently
                self.tick_errors += 1
                log.exception("control tick failed")
                self.agent.sup.on_fault("agent_exception", self.clock())
            self._flush()
            next_t += period
            delay = next_t - self.clock()
            if delay < -period:  # fell behind: resync instead of bursting catch-up ticks
                next_t = self.clock()
                delay = 0.0
            await asyncio.sleep(max(delay, 0.0))

    async def start(self, host: str, port: int, ssl_context: ssl.SSLContext | None) -> Server:
        self.agent.connect(self.clock())
        server = await serve(
            self._handler, host, port,
            ssl=ssl_context,
            process_request=self._process_request,
            max_size=MAX_MESSAGE_BYTES,
            ping_interval=1.0,
            ping_timeout=1.0,
        )
        self._loop_task = asyncio.create_task(self._control_loop())
        return server

    async def stop(self, server: Server) -> None:
        if self._loop_task is not None:
            self._loop_task.cancel()
        server.close()
        await server.wait_closed()


def _load_token(args: argparse.Namespace) -> str:
    if args.token_file:
        with open(args.token_file) as f:
            return f.read().strip()
    token = os.environ.get("SO101_GATEWAY_TOKEN", "")
    if not token:
        raise SystemExit("set SO101_GATEWAY_TOKEN or pass --token-file")
    return token


def main() -> None:
    ap = argparse.ArgumentParser(description="SO-101 Local Robot Agent gateway")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--token-file")
    ap.add_argument("--cert", help="TLS certificate (PEM)")
    ap.add_argument("--key", help="TLS private key (PEM)")
    ap.add_argument("--allow-insecure", action="store_true",
                    help="plain ws:// for LAN development only (SPEC §11.2 requires WSS)")
    ap.add_argument("--mock", action="store_true", help="use MockRobot (required until robot_worker exists)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if not args.mock:
        raise SystemExit("real SO-101 robot_worker is not implemented yet; run with --mock")
    if bool(args.cert) != bool(args.key):
        raise SystemExit("--cert and --key go together")
    if not args.cert and not args.allow_insecure:
        raise SystemExit("refusing to serve without TLS; pass --cert/--key or --allow-insecure")

    ctx = None
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)

    from .mocks import MockRobot, ScriptedPolicy

    outbox = Outbox()
    agent = RobotAgent(MockRobot(), ScriptedPolicy(), outbox)
    gateway = Gateway(agent, outbox, _load_token(args))

    async def run() -> None:
        await gateway.start(args.host, args.port, ctx)
        log.info("gateway listening on %s://%s:%d", "wss" if ctx else "ws", args.host, args.port)
        await asyncio.Future()

    asyncio.run(run())


if __name__ == "__main__":
    main()
