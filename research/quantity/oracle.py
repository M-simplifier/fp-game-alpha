#!/usr/bin/env python3
"""Independent unbounded-Python-integer oracle; no imported Haskell logic."""
import itertools
import random
M = 9_000_000_000_000
I64_MIN, I64_MAX = -(2**63), 2**63 - 1

def classification(n):
    if n < 0:
        return "ERR\tQuantityUnderflow"
    if n > M:
        return "ERR\tQuantityOverflow"
    return f"OK\t{n}"

def expected(parts):
    op = parts[0]
    if op == "max": return f"MAX\t{M}"
    if op == "zero": return "OK\t0"
    if op == "int64-min": return f"MIN\t{I64_MIN}"
    if op == "int64-max": return f"MAX\t{I64_MAX}"
    if op == "mk": return classification(int(parts[1]))
    a, b = map(int, parts[1:])
    assert 0 <= a <= M and 0 <= b <= M
    return classification(a + b if op == "add" else a - b)

def vectors():
    for cmd in ("max", "zero", "int64-min", "int64-max"):
        yield "metadata", cmd
    constructor = set(range(-4096, 4097))
    constructor.update(range(M - 4096, M + 4097))
    for point in (I64_MIN, I64_MAX, -(2**64), 2**64, -(2**128), 2**128):
        constructor.update(range(point - 4, point + 5))
    for power in (31, 32, 40, 43, 44, 62, 63, 64, 65, 127, 128, 255, 256, 1024, 4096):
        for sign in (-1, 1):
            for offset in (-1, 0, 1):
                constructor.add(sign * 2**power + offset)
    constructor.update((-10**1000, 10**1000))
    for n in sorted(constructor):
        yield "mk_boundaries_dense_huge", f"mk {n}"
    # Every ordered pair in the two dense endpoint neighborhoods.
    dense = list(range(256)) + list(range(M - 255, M + 1))
    for a, b in itertools.product(dense, repeat=2):
        for op in ("add", "sub"):
            yield "dense_endpoint_pairs", f"{op} {a} {b}"
    boundary = sorted(set([0, 1, 2, 127, 128, 255, 256, 257,
        2**31-1, 2**31, 2**31+1, 2**32-1, 2**32, 2**32+1,
        M//2-1, M//2, M//2+1, M-257, M-256, M-255, M-2, M-1, M]))
    for a, b in itertools.product(boundary, repeat=2):
        for op in ("add", "sub"):
            yield "boundary_pairs", f"{op} {a} {b}"
    # Exercise add's overflow boundary and sub's zero boundary at 4097 positions.
    for a in range(4097):
        for offset in (-1, 0, 1):
            b = M - a + offset
            if 0 <= b <= M:
                yield "add_threshold_frontier", f"add {a} {b}"
                yield "add_threshold_frontier", f"add {b} {a}"
            b = a + offset
            if 0 <= b <= M:
                yield "sub_threshold_frontier", f"sub {a} {b}"
                yield "sub_threshold_frontier", f"sub {b} {a}"
    rng = random.Random(60020261004)
    for _ in range(20000):
        a, b = rng.randrange(M + 1), rng.randrange(M + 1)
        for op in ("add", "sub"):
            yield "seeded_full_range_pairs", f"{op} {a} {b}"
