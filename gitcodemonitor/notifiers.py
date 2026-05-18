from __future__ import annotations

from dataclasses import dataclass

from .state import MonitorState


@dataclass(frozen=True)
class Delivery:
    channel: str
    target: str
    message: str


class Notifier:
    channel = "generic"

    def send(self, target: str, message: str) -> None:
        raise NotImplementedError


class FakeNotifier(Notifier):
    def __init__(self, channel: str):
        self.channel = channel
        self.deliveries: list[Delivery] = []

    def send(self, target: str, message: str) -> None:
        self.deliveries.append(Delivery(self.channel, target, message))


class FeishuNotifier(FakeNotifier):
    def __init__(self):
        super().__init__("feishu")


class TelegramNotifier(FakeNotifier):
    def __init__(self):
        super().__init__("telegram")


def notify_with_audit(notifier: Notifier, state: MonitorState, target: str, message: str) -> None:
    notifier.send(target, message)
    state.record_audit("notify", "delivered", channel=notifier.channel, target=target)

