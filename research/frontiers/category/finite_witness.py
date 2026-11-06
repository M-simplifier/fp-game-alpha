"""Finite mathematical witnesses, not a game engine or an APL/Prolog backend."""

from collections import deque
from itertools import product
import json
from pathlib import Path


def subsets(n):
    return [frozenset(i for i in range(n) if bits & (1 << i)) for bits in range(1 << n)]


def compose_rel(r, s):
    return {(a, c) for a, b in r for b2, c in s if b == b2}


def matrix(r, n):
    return [[(i, j) in r for j in range(n)] for i in range(n)]


def bool_multiply(a, b):
    return [[any(x and y for x, y in zip(row, col)) for col in zip(*b)] for row in a]


def matrix_edges(a):
    return {(i, j) for i, row in enumerate(a) for j, val in enumerate(row) if val}


def bfs(edges, start):
    visited = {start}
    queue = deque([start])
    while queue:
        at = queue.popleft()
        for src, dst in edges:
            if src == at and dst not in visited:
                visited.add(dst)
                queue.append(dst)
    return visited


def matrix_closure(a, start):
    reachable = [i == start for i in range(len(a))]
    while True:
        after = [reachable[j] or any(reachable[i] and a[i][j] for i in range(len(a)))
                 for j in range(len(a))]
        if after == reachable:
            return {i for i, val in enumerate(after) if val}
        reachable = after


def timed_step(state, action):
    """Four rooms 0..3. Entry to room 3 is allowed at arrival times 4,8,... ."""
    room, tick = state
    arrival = tick + 1
    target = min(3, room + 1) if action == "forward" else room
    if room == 2 and target == 3 and arrival % 4 != 0:
        target = room
    return target, arrival


def replay(actions):
    state = (0, 0)
    trace = [state]
    for action in actions:
        state = timed_step(state, action)
        trace.append(state)
    return trace


def timeless_step(room, action):
    return min(3, room + 1) if action == "forward" else room


def timed_layers(horizon):
    layers = [{(0, 0)}]
    for _ in range(horizon):
        layers.append({timed_step(s, a) for s in layers[-1] for a in ("forward", "wait")})
    return layers


def run():
    counts = {}
    relations2 = [set(e for i, e in enumerate(product(range(2), repeat=2)) if bits & (1 << i))
                  for bits in range(16)]
    for r, s in product(relations2, repeat=2):
        assert compose_rel(r, s) == matrix_edges(bool_multiply(matrix(r, 2), matrix(s, 2)))
    counts["relation_matrix_compositions"] = 256

    for bits in range(512):
        edges = {edge for i, edge in enumerate(product(range(3), repeat=2)) if bits & (1 << i)}
        for start in range(3):
            assert bfs(edges, start) == matrix_closure(matrix(edges, 3), start)
    counts["reachability_comparisons"] = 1536

    footprints = ({0, 1}, {1, 2}, {2, 3}, {4, 5})

    def cover(poses):
        return set().union(*(footprints[p] for p in poses))

    def fits(free):
        return {p for p, cells in enumerate(footprints) if cells <= free}

    for poses, free in product(subsets(4), subsets(6)):
        assert (cover(poses) <= free) == (poses <= fits(free))
    counts["footprint_adjunction_instances"] = 1024
    for f1, f2 in product(subsets(6), repeat=2):
        assert fits(f1 & f2) == fits(f1) & fits(f2)
    counts["constraint_intersections"] = 4096
    assert {0, 1} <= fits(set(range(6)))
    assert footprints[0] & footprints[1] == {1}

    tested_traces = 0
    deadline_rows = []
    for horizon in range(9):
        layers = timed_layers(horizon)
        brute = {tuple(replay(actions)[-1]) for actions in product(("forward", "wait"), repeat=horizon)}
        tested_traces += 2 ** horizon
        assert layers[-1] == brute
        abstract = {0}
        for layer in layers:
            assert {room for room, _ in layer} <= abstract
            abstract |= {timeless_step(room, a) for room in abstract for a in ("forward", "wait")}
        route = next((list(actions) for actions in product(("forward", "wait"), repeat=horizon)
                      if replay(actions)[-1][0] == 3), None)
        deadline_rows.append({"deadline": horizon, "timed_possible": route is not None,
                              "time_erased_possible": horizon >= 3, "witness": route})
    counts["timed_traces"] = tested_traces
    assert deadline_rows[3]["time_erased_possible"] and not deadline_rows[3]["timed_possible"]
    assert deadline_rows[4]["timed_possible"]

    # Both states are reachable, and their current position projections agree.
    left, right = (2, 2), (2, 3)
    assert left in timed_layers(2)[-1] and right in timed_layers(3)[-1]
    assert left[0] == right[0]
    assert timed_step(left, "forward")[0] != timed_step(right, "forward")[0]

    # Pure permutations of representation preserve every local transition here.
    encode = lambda state: state[0] * 9 + state[1]
    decode = lambda value: divmod(value, 9)
    table = {(encode((room, tick)), action): encode(timed_step((room, tick), action))
             for room in range(4) for tick in range(8) for action in ("forward", "wait")}
    for room, tick, action in product(range(4), range(8), ("forward", "wait")):
        assert decode(table[(encode((room, tick)), action)]) == timed_step((room, tick), action)
    counts["state_encoding_transitions"] = 64

    # Same nine terminal action pairs, different information and legal policies.
    hidden_policies = [(choice,) * 3 for choice in range(3)]
    visible_policies = list(product(range(3), repeat=3))
    outcomes = lambda policies: {(a, policy[a]) for a in range(3) for policy in policies}
    wins_every_time = lambda policy: all((policy[a] - a) % 3 == 1 for a in range(3))
    assert outcomes(hidden_policies) == outcomes(visible_policies)
    assert len(outcomes(hidden_policies)) == 9
    hidden_wins = sum(map(wins_every_time, hidden_policies))
    visible_wins = sum(map(wins_every_time, visible_policies))
    assert hidden_wins == 0 and visible_wins == 1
    counts["observation_restricted_policies"] = len(hidden_policies) + len(visible_policies)

    result = {
        "scope": "finite mathematical examples; no production game equivalence or speed claim",
        "checks": counts,
        "counterexamples": {
            "individually_legal_but_jointly_overlapping": [0, 1],
            "forget_clock": {"same_visible_room": 2, "states": [left, right],
                             "after_forward": [timed_step(left, "forward"), timed_step(right, "forward")]},
            "same_outcomes_different_strategies": {
                "terminal_action_pairs": 9, "hidden_winning_policies": hidden_wins,
                "visible_winning_policies": visible_wins,
                "meaning": "B commits without seeing A versus B observes A before committing"},
        },
        "deadlines": deadline_rows,
    }
    destination = Path(__file__).with_name("finite-results.json")
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"result": "PASS", **counts, "deadline_3": deadline_rows[3], "deadline_4": deadline_rows[4]}, ensure_ascii=False))


if __name__ == "__main__":
    run()
