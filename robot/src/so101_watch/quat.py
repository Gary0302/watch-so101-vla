"""Minimal unit-quaternion helpers (w, x, y, z). No Euler angles anywhere (SPEC §5.2)."""

from __future__ import annotations

import math
from collections.abc import Iterable

Quat = tuple[float, float, float, float]
Vec3 = tuple[float, float, float]


def normalize(q: Iterable[float]) -> Quat:
    w, x, y, z = q
    n = math.sqrt(w * w + x * x + y * y + z * z)
    if n < 1e-9:
        raise ValueError("zero quaternion")
    return (w / n, x / n, y / n, z / n)


def conj(q: Quat) -> Quat:
    w, x, y, z = q
    return (w, -x, -y, -z)


def mul(a: Quat, b: Quat) -> Quat:
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def log_so3(q: Quat) -> Vec3:
    """Rotation vector (axis * angle, rad) of the shortest rotation q represents."""
    w, x, y, z = normalize(q)
    if w < 0:
        w, x, y, z = -w, -x, -y, -z
    s = math.sqrt(x * x + y * y + z * z)
    if s < 1e-9:
        return (2 * x, 2 * y, 2 * z)
    k = 2 * math.atan2(s, w) / s
    return (x * k, y * k, z * k)


def from_rotvec(r: Vec3) -> Quat:
    angle = math.sqrt(sum(c * c for c in r))
    if angle < 1e-12:
        return (1.0, 0.0, 0.0, 0.0)
    s = math.sin(angle / 2) / angle
    return (math.cos(angle / 2), r[0] * s, r[1] * s, r[2] * s)


def average(qs: Iterable[Quat]) -> Quat:
    """Sign-aligned normalized mean; accurate for the tightly clustered samples of a still wrist."""
    qs = list(qs)
    if not qs:
        raise ValueError("no quaternions to average")
    ref = qs[0]
    acc = [0.0, 0.0, 0.0, 0.0]
    for q in qs:
        sign = 1.0 if sum(a * b for a, b in zip(q, ref)) >= 0 else -1.0
        for i in range(4):
            acc[i] += sign * q[i]
    return normalize(acc)
