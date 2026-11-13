"""Writes a minimal Scrap Mechanic world file for the tests and the screenshots.

    python make_world.py <out.db> <size in MB> [workshop id ...]

It is a real SQLite file with the game's Game table, whose "mods" column lists the given
Workshop items the way the game stores them: a 4-byte count, then per mod an 8-byte
Workshop ID and 16 further bytes, all big-endian. A Pad table brings it up to the size.
"""
import os
import sqlite3
import struct
import sys

out, size_mb, ids = sys.argv[1], float(sys.argv[2]), [int(x) for x in sys.argv[3:]]
if os.path.exists(out):
    os.remove(out)
mods = struct.pack(">I", len(ids)) + b"".join(struct.pack(">Q", i) + bytes(16) for i in ids)
con = sqlite3.connect(out)
con.execute("create table Game (savegameversion integer, flags integer, seed integer, gametick integer, mods blob, uniqueIds blob, gameversion text, buildnumber integer)")
con.execute("insert into Game values (30, 15, 1, 1, ?, ?, '1.0.7a', 901)", (mods, bytes(72)))
con.execute("create table Pad (data blob)")
con.execute("insert into Pad values (zeroblob(?))", (int(size_mb * 1024 * 1024),))
con.commit()
con.close()
