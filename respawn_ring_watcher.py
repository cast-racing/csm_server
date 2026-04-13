from __future__ import annotations

import argparse
import mmap
import os
import struct
import subprocess
import time

MAGIC = b"CSM1"
HEADER_SIZE = 12  # magic(4) + head:uint32 + tail:uint32
DEFAULT_RESTART_CMD = "~/ros2_ws/src/robot_bringup/scripts/start_robot.sh"


class Ring:
    def __init__(self, path: str, slots: int, slot_size: int):
        self.path = path
        self.slots = slots
        self.slot_size = slot_size
        self._open_file()

    def _open_file(self) -> None:
        size = HEADER_SIZE + self.slots * self.slot_size
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o666)
        try:
            current = os.path.getsize(self.path)
            if current != size:
                os.ftruncate(fd, size)
        finally:
            self.mm = mmap.mmap(fd, size, access=mmap.ACCESS_WRITE)
            os.close(fd)
        self._head_tail()

    def _head_tail(self) -> tuple[int, int]:
        magic, head, tail = struct.unpack_from("<4sII", self.mm, 0)
        if magic != MAGIC or head >= self.slots or tail >= self.slots:
            self._store_head_tail(0, 0)
            return 0, 0
        return head, tail

    def _store_head_tail(self, head: int, tail: int) -> None:
        struct.pack_into("<4sII", self.mm, 0, MAGIC, head, tail)

    def pop(self) -> bytes | None:
        head, tail = self._head_tail()
        if tail == head:
            return None
        base = HEADER_SIZE + tail * self.slot_size
        length = struct.unpack_from("<H", self.mm, base)[0]
        if length > self.slot_size - 2:
            self._store_head_tail(head, (tail + 1) % self.slots)
            return None
        data = bytes(self.mm[base + 2 : base + 2 + length])
        self._store_head_tail(head, (tail + 1) % self.slots)
        return data

    def drain(self) -> int:
        drained = 0
        while True:
            raw = self.pop()
            if raw is None:
                return drained
            drained += 1


def parse_event(raw: bytes) -> dict[str, str]:
    # Format: unix_ts|car_index|reason|sim_timestamp
    txt = raw.decode("utf-8", errors="replace")
    parts = txt.split("|", 3)
    return {
        "unix_ts": parts[0] if len(parts) > 0 else "",
        "car_index": parts[1] if len(parts) > 1 else "",
        "reason": parts[2] if len(parts) > 2 else "",
        "sim_timestamp": parts[3] if len(parts) > 3 else "",
        "raw": txt,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch respawn ring events and run a restart command.")
    parser.add_argument("--ring", default=os.environ.get("RESPAWN_RING_PATH", "/tmp/csm_respawn.ring"))
    parser.add_argument("--slots", type=int, default=int(os.environ.get("RESPAWN_RING_SLOTS", "128")))
    parser.add_argument("--slot-size", type=int, default=int(os.environ.get("RESPAWN_RING_SLOT_SIZE", "1024")))
    parser.add_argument(
        "--restart-cmd",
        default=os.environ.get("RESPAWN_RESTART_CMD", DEFAULT_RESTART_CMD),
        help="Shell command to restart your stack.",
    )
    parser.add_argument("--poll", type=float, default=0.05, help="Polling interval in seconds.")
    parser.add_argument(
        "--dedupe-window",
        type=float,
        default=float(os.environ.get("RESPAWN_DEDUPE_WINDOW_SEC", "2.0")),
        help="Skip duplicate event IDs seen within this many seconds.",
    )
    parser.add_argument(
        "--drain-on-start",
        action="store_true",
        default=True,
        help="Discard any stale queued events at startup (default: enabled).",
    )
    parser.add_argument(
        "--no-drain-on-start",
        action="store_false",
        dest="drain_on_start",
        help="Process queued events that existed before watcher startup.",
    )
    args = parser.parse_args()

    if not args.restart_cmd:
        print("Set --restart-cmd (or RESPAWN_RESTART_CMD) to define what should be restarted.")
        return 2

    ring = Ring(args.ring, args.slots, args.slot_size)
    if args.drain_on_start:
        dropped = ring.drain()
        if dropped:
            print(f"Dropped {dropped} stale respawn event(s) on startup")
    print(f"Watching {args.ring} for respawn events...")

    last_event_id = None
    last_event_time = 0.0

    while True:
        raw = ring.pop()
        if not raw:
            time.sleep(args.poll)
            continue

        evt = parse_event(raw)
        event_id = f"{evt['unix_ts']}|{evt['car_index']}|{evt['sim_timestamp']}"
        now = time.monotonic()
        if event_id == last_event_id and (now - last_event_time) < args.dedupe_window:
            continue
        last_event_id = event_id
        last_event_time = now

        print(
            "Respawn event:",
            f"car={evt['car_index']}",
            f"reason={evt['reason']}",
            f"sim_ts={evt['sim_timestamp']}",
        )

        proc = subprocess.run(args.restart_cmd, shell=True, check=False)
        if proc.returncode != 0:
            print(f"Restart command failed with code {proc.returncode}")


if __name__ == "__main__":
    raise SystemExit(main())
