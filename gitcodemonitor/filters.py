from __future__ import annotations

from .events import MonitorEvent


def is_cangjiepl(event: MonitorEvent) -> bool:
    return event.author == "CangjiePL" or "gitcode.com/CangjiePL" in event.url


def is_exact_start_build(event: MonitorEvent) -> bool:
    return event.text.strip().lower() == "start build"


def has_self_marker(event: MonitorEvent, marker: str = "<!-- metis-gitcode-monitor -->") -> bool:
    return marker in event.text


def should_process(event: MonitorEvent, marker: str = "<!-- metis-gitcode-monitor -->") -> bool:
    return not (
        is_cangjiepl(event) or
        is_exact_start_build(event) or
        has_self_marker(event, marker)
    )
