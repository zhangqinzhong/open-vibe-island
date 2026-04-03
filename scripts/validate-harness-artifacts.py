#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"Smoke failed: {message}")


def load_json(path: pathlib.Path) -> dict:
    if not path.exists():
        fail(f"missing file at {path}")
    return json.loads(path.read_text())


def find_overlay_window(report: dict) -> dict:
    windows = report.get("windows") or []
    overlay = next((window for window in windows if window.get("kind") == "overlay"), None)
    if overlay is None:
        fail("report is missing an overlay window artifact")
    return overlay


def collect_ax_strings(node: dict, labels: set[str], button_labels: set[str], text_values: set[str]) -> None:
    label = node.get("label")
    if isinstance(label, str) and label:
        labels.add(label)
        role = (node.get("role") or "").lower()
        if "button" in role:
            button_labels.add(label)

    value = node.get("value")
    if isinstance(value, str) and value:
        text_values.add(value)

    for child in node.get("children") or []:
        collect_ax_strings(child, labels, button_labels, text_values)


def require_frame_between(frame: dict, *, width: tuple[float, float], height: tuple[float, float], context: str) -> None:
    frame_width = frame.get("width")
    frame_height = frame.get("height")
    if not isinstance(frame_width, (int, float)) or not isinstance(frame_height, (int, float)):
        fail(f"{context} is missing width/height")

    min_width, max_width = width
    min_height, max_height = height
    if not (min_width <= frame_width <= max_width):
        fail(f"{context} width {frame_width} is outside expected range {width}")
    if not (min_height <= frame_height <= max_height):
        fail(f"{context} height {frame_height} is outside expected range {height}")


def assert_contains_any(haystack: set[str], needles: list[str], context: str) -> None:
    if not any(needle in item for item in haystack for needle in needles):
        fail(f"{context} is missing any of {needles}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-harness-artifacts.py <report.json>")

    report_path = pathlib.Path(sys.argv[1])
    report = load_json(report_path)
    overlay = find_overlay_window(report)

    accessibility_path = overlay.get("accessibilityPath")
    if not accessibility_path:
        fail("overlay window is missing accessibilityPath")

    ax_path = report_path.parent / accessibility_path
    ax_tree = load_json(ax_path)

    labels: set[str] = set()
    button_labels: set[str] = set()
    text_values: set[str] = set()
    collect_ax_strings(ax_tree, labels, button_labels, text_values)

    summary = overlay.get("accessibilitySummary") or {}
    labels.update(summary.get("labels") or [])
    button_labels.update(summary.get("buttonLabels") or [])
    text_values.update(summary.get("textValues") or [])

    scenario = report.get("scenario")
    if not isinstance(scenario, str) or not scenario:
        fail("report is missing scenario")

    island_surface = report.get("islandSurface") or ""
    notch_status = report.get("notchStatus")
    overlay_frame = overlay.get("frame") or {}

    if scenario == "closed":
        if notch_status != "closed":
            fail(f"expected closed notch, got {notch_status!r}")
        if island_surface != "sessionList":
            fail(f"expected closed scenario to use sessionList surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(200, 320),
            height=(35, 60),
            context="closed overlay frame",
        )
        if "9" not in text_values:
            fail("closed scenario is missing the live session count value")

    elif scenario == "sessionList":
        if notch_status != "opened":
            fail(f"expected opened notch for sessionList, got {notch_status!r}")
        if island_surface != "sessionList":
            fail(f"expected sessionList surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(680, 780),
            height=(360, 500),
            context="sessionList overlay frame",
        )
        if len(button_labels) < 3:
            fail("expected sessionList to expose multiple actionable row buttons")
        assert_contains_any(text_values, ["sessions hidden"], "sessionList text values")

    elif scenario == "approvalCard":
        if notch_status != "opened":
            fail(f"expected opened notch for approvalCard, got {notch_status!r}")
        if not island_surface.startswith("approvalCard:"):
            fail(f"expected approvalCard surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(660, 760),
            height=(300, 390),
            context="approvalCard overlay frame",
        )
        if "Deny" not in button_labels:
            fail("missing required approval button label 'Deny'")
        if not ({"Allow", "Allow Once"} & button_labels):
            fail("missing allow-style approval button label")

    elif scenario == "questionCard":
        if notch_status != "opened":
            fail(f"expected opened notch for questionCard, got {notch_status!r}")
        if not island_surface.startswith("questionCard:"):
            fail(f"expected questionCard surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(660, 760),
            height=(280, 340),
            context="questionCard overlay frame",
        )
        required = {"10 秒", "鼠标离开收起", "都要"}
        if not required.issubset(button_labels):
            fail(f"missing question options {sorted(required - button_labels)}")

    elif scenario == "completionCard":
        if notch_status != "opened":
            fail(f"expected opened notch for completionCard, got {notch_status!r}")
        if not island_surface.startswith("completionCard:"):
            fail(f"expected completionCard surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(660, 760),
            height=(240, 320),
            context="completionCard overlay frame",
        )
        if "Done" not in text_values:
            fail("completionCard is missing 'Done' text")

    elif scenario == "longCompletionCard":
        if notch_status != "opened":
            fail(f"expected opened notch for longCompletionCard, got {notch_status!r}")
        if not island_surface.startswith("completionCard:"):
            fail(f"expected longCompletionCard to remain on completionCard surface, got {island_surface!r}")
        require_frame_between(
            overlay_frame,
            width=(660, 760),
            height=(240, 320),
            context="longCompletionCard overlay frame",
        )
        if "Done" not in text_values:
            fail("longCompletionCard is missing 'Done' text")
        assert_contains_any(text_values, ["README.md", "worktree"], "longCompletionCard text values")

    else:
        fail(f"unsupported scenario {scenario!r}")

    print(
        f"{scenario}: notch={notch_status}, surface={island_surface}, "
        f"frame={overlay_frame.get('width')}x{overlay_frame.get('height')}, "
        f"buttons={sorted(button_labels)}"
    )


if __name__ == "__main__":
    main()
