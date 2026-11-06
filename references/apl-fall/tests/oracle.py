"""Independent cell-list oracle; Python is used only by this test program.

The APL implementation gathers a prebuilt incidence table. This oracle instead
walks four (row,column) cells for each candidate, and uses a queue for reach.
"""
from __future__ import annotations

from collections import deque
from pathlib import Path
import json
import os
import random
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("ARRAY_FALL_RUNTIME", str(ROOT / ".runtime")))
EVIDENCE = ROOT / ".scratch" / "evidence"
HEIGHT, WIDTH, NR, NC, PLANE, NPOSE = 22, 10, 25, 13, 325, 1300
BASE = [
    (4, [(1, 0), (1, 1), (1, 2), (1, 3)]),
    (3, [(0, 0), (1, 0), (1, 1), (1, 2)]),
    (3, [(0, 2), (1, 0), (1, 1), (1, 2)]),
    (2, [(0, 0), (0, 1), (1, 0), (1, 1)]),
    (3, [(0, 1), (0, 2), (1, 0), (1, 1)]),
    (3, [(0, 1), (1, 0), (1, 1), (1, 2)]),
    (3, [(0, 0), (0, 1), (1, 1), (1, 2)]),
]
KICKS = [(0, 0), (0, -1), (0, 1), (-1, 0), (0, -2), (0, 2), (-2, 0)]
SHAPES: list[list[list[tuple[int, int]]]] = []
for size, initial in BASE:
    cells = initial
    orientations = []
    for _ in range(4):
        orientations.append(sorted(cells))
        cells = [(col, size - 1 - row) for row, col in cells]
    assert sorted(cells) == sorted(initial)
    SHAPES.append(orientations)


def decode(index: int) -> tuple[int, int, int]:
    orientation, at = divmod(index, PLANE)
    row, col = divmod(at, NC)
    return orientation, row - 3, col - 3


def encode(orientation: int, row: int, col: int) -> int | None:
    if not (0 <= orientation < 4 and -3 <= row < 22 and -3 <= col < 10):
        return None
    return orientation * PLANE + (row + 3) * NC + col + 3


def fits(board: list[int], kind: int, pose: tuple[int, int, int]) -> bool:
    orientation, row, col = pose
    for dr, dc in SHAPES[kind][orientation]:
        r, c = row + dr, col + dc
        if r < 0 or r >= HEIGHT or c < 0 or c >= WIDTH:
            return False
        if board[r * WIDTH + c] != 0:
            return False
    return True


def move(board: list[int], kind: int, index: int, action: int) -> int:
    orientation, row, col = decode(index)
    if action < 3:
        dr, dc = [(0, -1), (0, 1), (1, 0)][action]
        candidate = encode(orientation, row + dr, col + dc)
        if candidate is not None and fits(board, kind, decode(candidate)):
            return candidate
        return index
    turn = (orientation + (1 if action == 3 else -1)) % 4
    for dr, dc in KICKS:
        candidate = encode(turn, row + dr, col + dc)
        if candidate is not None and fits(board, kind, decode(candidate)):
            return candidate
    return index


def descend(board: list[int], kind: int, index: int) -> int:
    orientation, row, col = decode(index)
    distance = 0
    while fits(board, kind, (orientation, row + distance + 1, col)):
        distance += 1
    return distance


def reach(board: list[int], kind: int, start: int) -> list[int]:
    reached = [0] * NPOSE
    reached[start] = 1
    queue = deque([start])
    while queue:
        current = queue.popleft()
        for action in range(5):
            dest = move(board, kind, current, action)
            if not reached[dest]:
                reached[dest] = 1
                queue.append(dest)
    return reached


def clear(board: list[int]) -> list[int]:
    rows = [board[r * WIDTH:(r + 1) * WIDTH] for r in range(HEIGHT)]
    keep = [row for row in rows if any(cell == 0 for cell in row)]
    return [0] * ((HEIGHT - len(keep)) * WIDTH) + sum(keep, [])


def demo_board() -> list[int]:
    board = [0] * 220
    for r in [20, 21]:
        for c in range(10):
            board[r * 10 + c] = 0 if c in [7, 8] else 7
    for c in range(5):
        board[16 * 10 + c] = 2
    for r in [17, 18, 19]:
        board[r * 10 + 4] = 2
    board[18 * 10 + 6] = board[19 * 10 + 6] = 6
    return board


def boards() -> list[tuple[str, list[int]]]:
    rng = random.Random(804213)
    result = [("empty", [0] * 220), ("full", [4] * 220), ("cavity", demo_board())]
    roof = [0] * 220
    for c in range(10):
        roof[10 * 10 + c] = 1
    result.append(("sealed_roof", roof))
    spawn = [0] * 220
    spawn[4] = 2
    spawn[15] = 3
    result.append(("hidden_spawn", spawn))
    stairs = [0] * 220
    for c in range(10):
        for r in range(12 + (c % 5), 22):
            stairs[r * 10 + c] = 1 + c % 7
    result.append(("stairs", stairs))
    for density in [0.08, 0.18, 0.35, 0.6]:
        board = [rng.randint(1, 7) if r >= 7 and rng.random() < density else 0
                 for r in range(22) for _ in range(10)]
        result.append((f"random_{density}", board))
    return result


def numbers(values: list[int]) -> str:
    return " ".join(str(value).replace("-", "¯") for value in values)


def output(label: str, expression: str) -> str:
    return f"unused←'{label}' Emit {expression}"


def run_apl(script: str) -> tuple[dict[str, list[int | float]], float]:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    source = EVIDENCE / "oracle-input.apl"
    source.write_text(script, encoding="utf-8")
    env = dict(os.environ, APL_LIB_ROOT=str(RUNTIME / "apl"))
    command = [str(RUNTIME / "apl" / "apl-2.0.exe"), "-s", "--noSV", "--rawCIN", "--OFF",
               "-f", str(ROOT / "apl" / "core.apl"), "-f", str(ROOT / "apl" / "inspect.apl"), "-f", str(source)]
    began = time.perf_counter()
    result = subprocess.run(command, cwd=EVIDENCE, env=env, capture_output=True, text=True,
                            encoding="utf-8", timeout=180)
    elapsed = time.perf_counter() - began
    (EVIDENCE / "oracle-output.txt").write_text(result.stdout, encoding="utf-8")
    if result.returncode or result.stderr.strip():
        raise AssertionError(f"GNU APL failed: {result.returncode}\n{result.stderr[:2000]}")
    parsed = {}
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        if "|" not in line:
            raise AssertionError(f"Unexpected GNU APL output (it returns 0 even for language errors): {line}")
        label, payload = line.split("|", 1)
        if label in parsed:
            raise AssertionError(f"Duplicate APL result label: {label}")
        parsed[label] = [float(item.replace("¯", "-")) if "." in item or "E" in item else int(item.replace("¯", "-"))
                         for item in payload.split()]
    return parsed, elapsed


def main() -> None:
    cases = boards()
    script = ["∇ z←label Emit values", "z←(label,'|',(⍕,values),⎕UCS 10) ⎕FIO[23] 1", "∇",
              "InitialSeed←314159", output("OFFSETS", "Offsets")]
    script += ["RotationLaw←1", "∇ z←TestC4 ignored;t;o;n;cells;flat;mask;initial", "t←0",
               "TYPE: n←Sizes[t]", "cells←Offsets[t;0;;]", "flat←(n×n)⍴0",
               "flat[(n×cells[;0])+cells[;1]]←1", "initial←n n⍴flat", "mask←initial", "o←0",
               "TURN: mask←⌽⍉mask", "o←o+1", "→(o<4)/TURN",
               "RotationLaw←RotationLaw∧(mask≡initial)∧(4=+/,mask)", "t←t+1", "→(t<7)/TYPE",
               "z←0", "∇", "unused←TestC4 0", output("ROTATIONLAW", "RotationLaw")]
    expectations = []
    field_checks = action_checks = drop_checks = reach_checks = witness_checks = 0
    for b, (name, board) in enumerate(cases):
        script.append("Board←22 10⍴" + numbers(board))
        for kind in range(7):
            prefix = f"{b}.{kind}"
            field = [int(fits(board, kind, decode(i))) for i in range(NPOSE)]
            expected_actions = [move(board, kind, i, a) for a in range(5) for i in range(NPOSE)]
            candidates = [i for i, legal in enumerate(field) if legal]
            # Every feasible start on empty, cavity and sealed-roof boards; diverse samples elsewhere.
            samples = candidates if b in [0, 2, 3] else candidates[::max(1, len(candidates) // 60)]
            expected_drops = [descend(board, kind, i) for i in samples]
            script += [f"Type←{kind}", "unused←Refresh 0", output("F" + prefix, "Field"),
                       output("A" + prefix, "Actions")]
            if samples:
                script += ["Samples←" + numbers(samples), "Drops←(⍴Samples)⍴0", "j←0",
                           "∇ z←TestDrops ignored;j", "j←0", "LOOP: Drops[j]←Field DropDistance Samples[j]",
                           "j←j+1", "→(j<(⍴Samples)[0])/LOOP", "z←0", "∇", "unused←TestDrops 0",
                           output("D" + prefix, "Drops")]
            start = encode(0, 0, 3)
            assert start is not None
            if field[start]:
                expected_reach = reach(board, kind, start)
                script += [f"Pose←{start}", "unused←ReachFrom Pose", output("R" + prefix, "Reachable"),
                           output("P" + prefix, "Parents"), output("W" + prefix, "ParentActions")]
                reach_checks += NPOSE
            else:
                expected_reach = None
            expectations.append((prefix, board, kind, field, expected_actions, samples, expected_drops, expected_reach))
            field_checks += NPOSE
            action_checks += 5 * NPOSE
            drop_checks += len(samples)
    # Clear by independent row lists, including multiple nonadjacent full rows and all-full board.
    clear_boards = [board for _, board in cases]
    rng = random.Random(481)
    for filled in [[21], [0, 5, 20, 21], [4, 7], list(range(22))]:
        board = [rng.randrange(8) if r not in filled else rng.randrange(1, 8)
                 for r in range(22) for _ in range(10)]
        clear_boards.append(board)
    for n, board in enumerate(clear_boards):
        script += ["Board←22 10⍴" + numbers(board), "Result←ClearRows Board", output(f"C{n}", "Result"),
                   output(f"CI{n}", "Result≡ClearRows Result")]
    # The collision field depends only on occupancy and shrinks as occupancy grows.
    script += ["Board←22 10⍴" + numbers(cases[2][1]), "Before←5 Feasible Board",
               "Board←22 10⍴(,Board)×1+7|⍳220", output("COLOR", "Before≡5 Feasible Board"),
               "Board[2;2]←6", output("MONO", "∧/(5 Feasible Board)≤Before")]
    # Actual game transition: fixture opening receives O, clears exactly two rows.
    script += ["unused←LoadDemo 0", "Mode←0", "Pose←PoseIndex 0 0 7", "unused←HardDrop 0",
               output("DOUBLE", "Score Lines Pieces Level LastClear"), output("DOUBLEBOARD", "Board")]
    # Saved witnesses are replayed through the same MoveAction used by game input.
    script += ["unused←LoadDemo 0", "SavedStart←Pose", "Targets←Supported/⍳PoseCount",
               "ReplayOK←1", "∇ z←TestWitnesses ignored;i;j;path;moved", "i←0",
               "TARGET: Pose←SavedStart", "path←Witness Targets[i]", "j←0", "→(0=⍴path)/CHECK",
               "ACTION: moved←MoveAction path[j]", "j←j+1", "→(j<(⍴path)[0])/ACTION",
               "CHECK: ReplayOK←ReplayOK∧Pose=Targets[i]", "i←i+1", "→(i<(⍴Targets)[0])/TARGET",
               "z←0", "∇", "unused←TestWitnesses 0", output("WITNESSES", "ReplayOK,(⍴Targets)[0]")]
    # Fixed-input replays compare full board, queue, RNG and numeric game state.
    script += ["∇ result←Replay seed;i;held;edges;unused", "unused←NewGame seed", "i←0",
               "LOOP: held←16⍴0", "edges←16⍴0", "held[0]←(30|i)<12", "held[1]←(30|i)>20",
               "held[2]←(70|i)>55", "edges[3]←0=17|i", "edges[4]←0=29|i", "edges[6]←0=43|i",
               "unused←held GameTick edges", "i←i+1", "→(i<900)/LOOP",
               "result←(,Board),Type,Pose,Seed,Score,Lines,Level,Pieces,Queue", "∇",
               "ReplayA←Replay 93177", "ReplayB←Replay 93177", output("REPLAY", "ReplayA≡ReplayB"),
               output("REPLAYSTATE", "ReplayA")]
    # Seven-bag generation and exact RNG state.
    script += ["Seed←314160", "Bags←⍬", "j←0", "∇ z←TestBags ignored;j", "j←0",
               "LOOP: Bags←Bags,NewBag 0", "j←j+1", "→(j<20)/LOOP", "z←0", "∇",
               "unused←TestBags 0", output("BAGS", "Bags"), output("BAGSEED", "Seed")]
    script += ["∇ z←RunTicks count;i;unused", "i←0", "LOOP: unused←TestHeld GameTick TestEdges",
               "TestEdges←16⍴0", "i←i+1", "→(i<count)/LOOP", "z←0", "∇",
               "unused←NewGame 314159", "TestHeld←16⍴0", "TestEdges←16⍴0", "TestHeld[0]←1",
               "unused←RunTicks 1", output("DAS1", "Poses[Pose;2]"), "unused←RunTicks 9",
               output("DAS10", "Poses[Pose;2]"), "unused←RunTicks 1", output("DAS11", "Poses[Pose;2]"),
               "unused←RunTicks 3", output("DAS14", "Poses[Pose;2]"),
               "unused←NewGame 314159", "TestHeld←16⍴0", "TestHeld[2]←1", "unused←RunTicks 12",
               output("SOFT", "Score,Poses[Pose;1]"),
               "unused←NewGame 314159", "TestHeld←16⍴0", "TestEdges[7]←1", "unused←RunTicks 90",
               output("PAUSE", "Mode ActiveTicks Pose"), "TestEdges[7]←1", "unused←RunTicks 1",
               output("RESUME", "Mode ActiveTicks"),
               "unused←NewGame 314159", "unused←HoldPiece 0", "HoldState←Hold Type CanHold",
               "unused←HoldPiece 0", output("HOLDGATE", "HoldState≡Hold Type CanHold"),
               "unused←HardDrop 0", output("HOLDREADY", "CanHold"), "unused←HoldPiece 0",
               output("HOLDSWAP", "Type CanHold"),
               "unused←NewGame 314159", "Pose←Pose+ColCount×Field DropDistance Pose",
               "TestHeld←16⍴0", "TestEdges←16⍴0", "unused←RunTicks 29", output("LOCK29", "Pieces LockTicks LockResets"),
               "unused←RunTicks 1", output("LOCK30", "Pieces"),
               "unused←NewGame 314159", "TestHeld←16⍴0", "TestHeld[2]←1", "unused←RunTicks 55",
               output("DESCENTBUDGET", "Poses[Pose;1],LockResets"),
               "LockTicks←17", "Moved←MoveAction 0", output("RESETFIRST", "Moved LockTicks LockResets"),
               "∇ z←TestResets ignored;j;moved", "j←1", "LOOP: LockTicks←17", "moved←MoveAction 2|j",
               "j←j+1", "→(j<16)/LOOP", "z←0", "∇", "unused←TestResets 0",
               output("RESETCAP", "LockTicks LockResets"),
               "unused←NewGame 314159", "Board[0;0]←7", "unused←Refresh 0", "unused←HardDrop 0",
               output("TOPOUT", "Mode"), "TestEdges←16⍴0", "TestEdges[8]←1", "unused←RunTicks 1",
               output("RESTART", "Mode Score Lines Pieces Hold ActiveTicks")]
    script += ["unused←NewGame 314159", "TestHeld←16⍴0", "TestEdges←16⍴0", "TestEdges[0]←1",
               "unused←RunTicks 1", output("TAPLEFT", "Poses[Pose;2]"), "TestEdges[1]←1",
               "unused←RunTicks 1", output("TAPRIGHT", "Poses[Pose;2]"), "TestEdges[0 1]←1",
               "unused←RunTicks 1", output("OPPOSED", "Poses[Pose;2]"), "TestEdges[2]←1",
               "unused←RunTicks 1", output("TAPDOWN", "Score,Poses[Pose;1]")]
    # Representative native interpreter timing: no rendering or process startup.
    script += ["Board←22 10⍴" + numbers(cases[2][1]), "∇ z←Benchmark ignored;j;began;f;a", "j←0",
               "began←⎕AI[2]", "LOOP: f←5 Feasible Board", "j←j+1", "→(j<200)/LOOP",
               "FieldMillis←⎕AI[2]-began", "j←0", "began←⎕AI[2]", "MAPS: a←BuildActions f",
               "j←j+1", "→(j<50)/MAPS", "ActionMillis←⎕AI[2]-began", "z←0", "∇",
               "unused←Benchmark 0", output("TIMING", "FieldMillis ActionMillis"), ")OFF"]
    actual, elapsed = run_apl("\n".join(script) + "\n")
    for kind in range(7):
        for orientation in range(4):
            at = (kind * 4 + orientation) * 8
            found = sorted(zip(actual["OFFSETS"][at:at + 8:2], actual["OFFSETS"][at + 1:at + 8:2]))
            assert found == SHAPES[kind][orientation], ("rotation/cell count", kind, orientation, found)
    assert actual["ROTATIONLAW"] == [1]
    for prefix, board, kind, field, actions, samples, drops, reachable in expectations:
        assert actual["F" + prefix] == field, ("field", prefix)
        assert actual["A" + prefix] == actions, ("ordered action destinations", prefix)
        if samples:
            assert actual["D" + prefix] == drops, ("prefix drop", prefix)
        if reachable is not None:
            assert actual["R" + prefix] == reachable, ("reachability", prefix)
            parents, edge = actual["P" + prefix], actual["W" + prefix]
            for child, is_reached in enumerate(reachable):
                if is_reached and parents[child] >= 0:
                    assert reachable[parents[child]] and move(board, kind, parents[child], edge[child]) == child
                    witness_checks += 1
    for n, board in enumerate(clear_boards):
        result = clear(board)
        assert actual[f"C{n}"] == result, ("first-axis clear/order", n)
        assert actual[f"CI{n}"] == [1], ("clear idempotence", n)
        removed = sum(all(board[r * 10 + c] != 0 for c in range(10)) for r in range(22))
        assert sum(x != 0 for x in result) == sum(x != 0 for x in board) - 10 * removed
    assert actual["COLOR"] == [1] and actual["MONO"] == [1]
    # 20 rows of drop distance = 40 points, plus two-line clear = 300.
    assert actual["DOUBLE"] == [340, 2, 1, 1, 2], actual["DOUBLE"]
    locked = demo_board()
    for r in [20, 21]:
        for c in [7, 8]:
            locked[r * 10 + c] = 4
    assert actual["DOUBLEBOARD"] == clear(locked)
    assert actual["WITNESSES"][0] == 1 and actual["WITNESSES"][1] > 0
    assert actual["REPLAY"] == [1]
    seed, expected_bags = 314160, []
    for _ in range(20):
        bag = list(range(7))
        for j in range(6, 0, -1):
            seed = (16807 * seed) % 2147483647
            k = seed % (j + 1)
            bag[j], bag[k] = bag[k], bag[j]
        assert sorted(bag) == list(range(7))
        expected_bags.extend(bag)
    assert actual["BAGS"] == expected_bags and actual["BAGSEED"] == [seed]
    assert [actual[key][0] for key in ["DAS1", "DAS10", "DAS11", "DAS14"]] == [2, 2, 1, 0]
    assert actual["SOFT"] == [4, 5]
    assert actual["PAUSE"] == [1, 0, 58] and actual["RESUME"] == [0, 0]
    assert actual["HOLDGATE"] == [1] and actual["HOLDREADY"] == [1] and actual["HOLDSWAP"] == [3, 0]
    assert actual["LOCK29"] == [0, 29, 0] and actual["LOCK30"] == [1]
    assert actual["DESCENTBUDGET"] == [20, 0] and actual["RESETFIRST"] == [1, 0, 1]
    assert actual["RESETCAP"] == [17, 15]
    assert actual["TOPOUT"] == [2] and actual["RESTART"] == [0, 0, 0, 0, -1, 0]
    assert actual["TAPLEFT"] == [2] and actual["TAPRIGHT"] == [3] and actual["OPPOSED"] == [3]
    assert actual["TAPDOWN"] == [1, 2]
    # Explicit negative blank-margin candidates and sealed roof counterexample.
    assert fits(cases[0][1], 0, (0, -1, 0))
    assert fits(cases[0][1], 0, (1, 0, -2))
    roof_start = encode(0, 0, 3)
    assert roof_start is not None and descend(cases[3][1], 0, roof_start) == 8
    assert fits(cases[3][1], 0, (0, 15, 3))
    summary = {
        "status": "passed", "boards": len(cases), "pieces": 7,
        "candidate_field_comparisons": field_checks, "ordered_action_comparisons": action_checks,
        "stepwise_drop_comparisons": drop_checks, "reachability_comparisons": reach_checks,
        "valid_parent_edges": witness_checks, "replayed_landing_witnesses": actual["WITNESSES"][1],
        "line_clear_cases": len(clear_boards), "deterministic_replay_ticks": 900,
        "mechanics_regressions": ["C4", "DAS_ARR", "soft_drop", "hold_gate_swap", "pause_resume", "lock_delay_30",
                                 "descent_preserves_reset_budget", "grounded_reset_cap_15", "pressed_only_taps",
                                 "opposed_horizontal_keys", "hidden_row_topout", "restart"],
        "apl_process_seconds": round(elapsed, 3),
        "field_1300_poses_mean_ms": actual["TIMING"][0] / 200,
        "five_action_maps_mean_ms": actual["TIMING"][1] / 50,
        "runtime": "GNU APL 2.0 / Windows local binary (SVN 3506M)",
    }
    (EVIDENCE / "oracle-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"GAME TEST FAILED: {error}", file=sys.stderr)
        raise
