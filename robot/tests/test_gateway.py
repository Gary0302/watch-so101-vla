"""Gateway over a real localhost websocket, MockRobot behind it."""

from __future__ import annotations

import asyncio
import json

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from conftest import PALM_DOWN
from so101_watch.agent import RobotAgent
from so101_watch.gateway import Gateway, Outbox
from so101_watch.mocks import MockRobot, ScriptedPolicy

TOKEN = "test-token-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


async def _start():
    outbox = Outbox()
    agent = RobotAgent(MockRobot(), ScriptedPolicy(), outbox)
    gw = Gateway(agent, outbox, TOKEN)
    server = await gw.start("127.0.0.1", 0, None)
    port = next(iter(server.sockets)).getsockname()[1]
    return gw, server, f"ws://127.0.0.1:{port}"


async def _recv_until(ws, pred, timeout=2.0):
    async def loop():
        while True:
            msg = json.loads(await ws.recv())
            if pred(msg):
                return msg
    return await asyncio.wait_for(loop(), timeout)


def _motion(seq, epoch):
    return json.dumps({
        "protocol_version": 1, "type": "watch.motion", "session_id": "s", "seq": seq,
        "sample_mono_ns": seq * 33_000_000, "quaternion_wxyz": [1, 0, 0, 0],
        "gyro_rad_s": [0, 0, 0], "gravity_g": list(PALM_DOWN), "control_epoch": epoch,
    })


def test_rejects_missing_or_wrong_token():
    async def go():
        gw, server, url = await _start()
        try:
            for headers in ({}, {"Authorization": "Bearer nope-nope-nope-nope"}):
                with pytest.raises(InvalidStatus) as e:
                    async with connect(url, additional_headers=headers):
                        pass
                assert e.value.response.status_code == 401
        finally:
            await gw.stop(server)
    asyncio.run(go())


def test_second_controller_is_refused():
    async def go():
        gw, server, url = await _start()
        try:
            async with connect(url, additional_headers=AUTH):
                with pytest.raises(InvalidStatus) as e:
                    async with connect(url, additional_headers=AUTH):
                        pass
                assert e.value.response.status_code == 409
        finally:
            await gw.stop(server)
    asyncio.run(go())


def test_double_tap_calibrate_to_manual_then_disconnect_holds():
    async def go():
        gw, server, url = await _start()
        try:
            async with connect(url, additional_headers=AUTH) as ws:
                hello = json.loads(await ws.recv())
                assert hello["type"] == "robot.status" and hello["mode"] == "HOLD"
                epoch = hello["control_epoch"]

                await ws.send(json.dumps({
                    "protocol_version": 1, "type": "control.intent", "request_id": "c-1",
                    "session_id": "s", "control_epoch": epoch, "intent": "DOUBLE_TAP",
                    "source": "test",
                }))
                ack = await _recv_until(ws, lambda m: m["type"] == "control.ack")
                assert ack["result"] == "accepted" and ack["mode"] == "CALIBRATING"
                epoch = ack["control_epoch"]

                seq = 0
                async def stream_until_manual():
                    nonlocal seq
                    while gw.agent.sup.mode.value != "MANUAL":
                        seq += 1
                        await ws.send(_motion(seq, epoch))
                        await asyncio.sleep(0.02)
                await asyncio.wait_for(stream_until_manual(), 3.0)
                await _recv_until(ws, lambda m: m["type"] == "robot.status" and m["mode"] == "MANUAL")

                await ws.send("{not json")
                err = await _recv_until(ws, lambda m: m["type"] == "error")
                assert "reason" in err
            await asyncio.sleep(0.1)
            assert gw.agent.sup.mode.value == "HOLD"
            assert gw.agent.sup.history[-1].reason == "client_disconnected"
            assert gw.tick_errors == 0
        finally:
            await gw.stop(server)
    asyncio.run(go())


def test_short_token_refused():
    with pytest.raises(ValueError):
        Gateway(RobotAgent(MockRobot(), ScriptedPolicy(), Outbox()), Outbox(), "short")
