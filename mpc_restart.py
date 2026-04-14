#!/usr/bin/env python3
"""Watch /state/odom and resend the FROM PIT trajectory after a teleport."""

from __future__ import annotations

import math
import subprocess
from typing import Optional, Tuple

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import QoSProfile

TOPIC = "/state/odom"
DISTANCE_THRESHOLD_M = 2.0
MAX_JUMP_DT_S = 0.1
COMMAND_COOLDOWN_S = 10.0
TRAJECTORY_COMMAND = ["ros2", "run", "trajectory_generator", "set_trajectory_node"]
TRAJECTORY_SELECTION = ""
MANEUVER_SELECTION = "6"
QOS_DEPTH = 1


class MpcRespawnMonitor(Node):
    def __init__(self) -> None:
        super().__init__("mpc_respawn_monitor")

        self._last_position: Optional[Tuple[float, float, float]] = None
        self._last_stamp_s: Optional[float] = None
        self._last_command_time = 0.0

        self._subscription = self.create_subscription(
            Odometry,
            TOPIC,
            self._odom_callback,
            QoSProfile(depth=QOS_DEPTH),
        )

        self.get_logger().info(
            "Watching %s for jumps > %.2f m within %.3f s",
            TOPIC,
            DISTANCE_THRESHOLD_M,
            MAX_JUMP_DT_S,
        )

    def _odom_callback(self, msg: Odometry) -> None:
        pos = msg.pose.pose.position
        current = (float(pos.x), float(pos.y), float(pos.z))
        stamp_s = float(msg.header.stamp.sec) + float(msg.header.stamp.nanosec) * 1e-9

        if self._last_position is None or self._last_stamp_s is None:
            self._last_position = current
            self._last_stamp_s = stamp_s
            return

        distance = math.dist(current, self._last_position)
        dt = stamp_s - self._last_stamp_s
        self._last_position = current
        self._last_stamp_s = stamp_s

        if dt <= 0.0 or dt > MAX_JUMP_DT_S:
            return
        if distance <= DISTANCE_THRESHOLD_M:
            return

        now = self.get_clock().now().nanoseconds * 1e-9
        if now - self._last_command_time < COMMAND_COOLDOWN_S:
            self.get_logger().warn(
                "Detected %.2f m jump but command is still in cooldown.",
                distance,
            )
            return

        self.get_logger().warn(
            "Detected %.2f m jump on %s in %.3f s; sending FROM PIT trajectory command.",
            distance,
            TOPIC,
            dt,
        )
        self._run_trajectory_command()
        self._last_command_time = now

    def _run_trajectory_command(self) -> None:
        command_input = f"{TRAJECTORY_SELECTION}\n{MANEUVER_SELECTION}\n"

        try:
            completed = subprocess.run(
                TRAJECTORY_COMMAND,
                input=command_input,
                capture_output=True,
                check=True,
                text=True,
            )
            if completed.stdout.strip():
                self.get_logger().info("Trajectory command stdout: %s", completed.stdout.strip())
            if completed.stderr.strip():
                self.get_logger().warn("Trajectory command stderr: %s", completed.stderr.strip())
        except subprocess.CalledProcessError as exc:
            self.get_logger().error("Trajectory command failed with code %s", exc.returncode)
            if exc.stdout.strip():
                self.get_logger().error("command stdout: %s", exc.stdout.strip())
            if exc.stderr.strip():
                self.get_logger().error("command stderr: %s", exc.stderr.strip())
        except Exception as exc:
            self.get_logger().error("Failed to run trajectory command: %s", exc)


def main() -> None:
    rclpy.init()
    node = MpcRespawnMonitor()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
