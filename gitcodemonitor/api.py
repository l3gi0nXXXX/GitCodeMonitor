from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Optional


class GitCodeAPIError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class UnauthorizedError(GitCodeAPIError):
    pass


class ForbiddenError(GitCodeAPIError):
    pass


class NotFoundError(GitCodeAPIError):
    pass


class RateLimitError(GitCodeAPIError):
    pass


class ServerError(GitCodeAPIError):
    pass


ERRORS = {
    401: UnauthorizedError,
    403: ForbiddenError,
    404: NotFoundError,
    429: RateLimitError,
}


@dataclass(frozen=True)
class Response:
    status: int
    body: Any
    headers: Optional[dict[str, str]] = None


Transport = Callable[[str, str, Optional[dict[str, Any]], Optional[dict[str, str]], Any], Response]


class UrllibTransport:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def __call__(
        self,
        method: str,
        path: str,
        params: Optional[dict[str, Any]],
        headers: Optional[dict[str, str]],
        payload: Any,
    ) -> Response:
        query = urllib.parse.urlencode(params or {})
        url = f"{self.base_url}{path}"
        if query:
            url = f"{url}?{query}"
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read().decode("utf-8")
                return Response(response.status, json.loads(raw) if raw else {}, dict(response.headers))
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            body = json.loads(raw) if raw else {"message": exc.reason}
            return Response(exc.code, body, dict(exc.headers))


class FakeTransport:
    def __init__(self, responses: Iterable[Response]):
        self.responses = list(responses)
        self.calls: list[tuple[str, str, Optional[dict[str, Any]], Optional[dict[str, str]], Any]] = []

    def __call__(
        self,
        method: str,
        path: str,
        params: Optional[dict[str, Any]],
        headers: Optional[dict[str, str]],
        payload: Any,
    ) -> Response:
        self.calls.append((method, path, params, headers, payload))
        if not self.responses:
            raise AssertionError("fake transport exhausted")
        return self.responses.pop(0)


class GitCodeClient:
    def __init__(
        self,
        base_url: str = "https://gitcode.com/api/v5",
        transport: Optional[Transport] = None,
        auth_header: Optional[str] = None,
    ):
        self.transport = transport or UrllibTransport(base_url)
        self.auth_header = auth_header

    def request(
        self,
        method: str,
        path: str,
        params: Optional[dict[str, Any]] = None,
        payload: Any = None,
    ) -> Any:
        headers = {"Accept": "application/json"}
        if self.auth_header:
            headers["Authorization"] = self.auth_header
        response = self.transport(method, path, params, headers, payload)
        if response.status >= 400:
            message = response.body.get("message", f"GitCode API returned {response.status}")
            error_type = ServerError if response.status >= 500 else ERRORS.get(response.status, GitCodeAPIError)
            raise error_type(response.status, message)
        return response.body

    def paginate(self, path: str, params: Optional[dict[str, Any]] = None, item_key: str = "items") -> list[Any]:
        items: list[Any] = []
        next_params = dict(params or {})
        while True:
            body = self.request("GET", path, next_params)
            page_items = body.get(item_key, body if isinstance(body, list) else [])
            items.extend(page_items)
            cursor = body.get("nextCursor") or body.get("next_cursor")
            if not cursor:
                break
            next_params["cursor"] = cursor
        return items

    def list_repositories(self, org: str) -> list[dict[str, Any]]:
        return self.paginate(f"/orgs/{org}/repos")
