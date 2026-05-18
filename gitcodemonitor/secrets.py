from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Union


SECRET_PATTERNS = (
    re.compile(r"(?i)\b(token|password|secret|cookie)\s*[:=]\s*[^\s]+"),
    re.compile(r"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9._\-]+"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
)


@dataclass(frozen=True)
class SecretValue:
    source: str
    value: str

    @property
    def redacted(self) -> str:
        return f"<redacted:{self.source}>"


class SecretResolver:
    def __init__(self, environ: Optional[Mapping[str, str]] = None):
        self.environ = environ if environ is not None else os.environ

    def token(self, value: str) -> SecretValue:
        return SecretValue("token", value)

    def cookie(self, value: str) -> SecretValue:
        return SecretValue("cookie", value)

    def env(self, name: str) -> SecretValue:
        if name not in self.environ:
            raise KeyError(f"missing environment secret {name}")
        return SecretValue(f"env:{name}", self.environ[name])

    def file(self, path: Union[str, Path]) -> SecretValue:
        secret_path = Path(path)
        value = secret_path.read_text(encoding="utf-8").strip()
        return SecretValue(f"file:{secret_path}", value)


def redact_text(text: str, secrets: Optional[list[SecretValue]] = None) -> str:
    redacted = text
    for secret in secrets or []:
        if secret.value:
            redacted = redacted.replace(secret.value, secret.redacted)
    for pattern in SECRET_PATTERNS:
        redacted = pattern.sub("<redacted:secret>", redacted)
    return redacted


def contains_secret(text: str) -> bool:
    return redact_text(text) != text
