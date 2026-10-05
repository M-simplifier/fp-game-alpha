# Frozen Python test oracle

These two files are exact bytes from commit `23239482865ef3a81db3b15b653882182f8eca74`, formerly `tools/fp_game.py` and `tools/scaffold.py`. Their MIT license is the [repository license](../../../../LICENSE). Hashes and purpose are in [provenance.json](provenance.json).

Only acceptance tests may invoke them, through the test adapter. They compare independent compiler/creation behavior and preserve historical evidence. They are not product entrypoints, compatibility support, or generated-game runtime helpers. Do not update them to agree with new behavior.
