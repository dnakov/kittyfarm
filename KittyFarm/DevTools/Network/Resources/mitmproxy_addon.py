"""
KittyFarm mitmproxy addon.

Emits one JSON line per completed flow (response or error) to stdout, so the
Swift-side NetworkMonitor can parse lines and surface them in the Network panel.

Request/response bodies are base64-encoded (truncated to 256KB) to keep the
stream binary-safe. Every line is prefixed with a magic tag so the Swift
parser can ignore mitmdump's own startup banner / debug chatter.
"""

import base64
import json
import sys
import time

from mitmproxy import http
from mitmproxy import ctx

MAX_BODY_BYTES = 256 * 1024
LINE_TAG = "KITTYFARM_FLOW"


def _encode_body(data):
    if data is None:
        return None, False
    if not isinstance(data, (bytes, bytearray)):
        try:
            data = bytes(data)
        except Exception:
            return None, False
    truncated = False
    if len(data) > MAX_BODY_BYTES:
        data = data[:MAX_BODY_BYTES]
        truncated = True
    return base64.b64encode(data).decode("ascii"), truncated


def _headers_list(headers):
    items = []
    if headers is None:
        return items
    for key, value in headers.items(multi=True):
        items.append([str(key), str(value)])
    return items


def _emit(payload):
    try:
        line = json.dumps(payload, ensure_ascii=False)
    except Exception as exc:
        ctx.log.warn("kittyfarm addon json error: %s" % exc)
        return
    sys.stdout.write(LINE_TAG + " " + line + "\n")
    sys.stdout.flush()


def _peer_port(flow):
    try:
        peer = flow.client_conn.peername
        if peer and len(peer) >= 2:
            return int(peer[1])
    except Exception:
        return None
    return None


def _build_payload(flow, error_message=None):
    request = flow.request
    response = flow.response
    body_req, req_trunc = _encode_body(request.raw_content if request else None)
    body_res, res_trunc = _encode_body(response.raw_content if response else None)
    started = request.timestamp_start if request and request.timestamp_start else time.time()
    ended = response.timestamp_end if response and response.timestamp_end else None
    duration_ms = None
    if ended and started:
        duration_ms = max(0.0, (ended - started) * 1000.0)

    bytes_sent = 0
    bytes_received = 0
    try:
        if request and request.raw_content is not None:
            bytes_sent = len(request.raw_content)
    except Exception:
        pass
    try:
        if response and response.raw_content is not None:
            bytes_received = len(response.raw_content)
    except Exception:
        pass

    return {
        "id": flow.id,
        "startedAt": started,
        "method": request.method if request else "",
        "url": request.pretty_url if request else "",
        "scheme": request.scheme if request else "",
        "host": request.pretty_host if request else "",
        "path": request.path if request else "",
        "status": response.status_code if response else None,
        "error": error_message,
        "requestHeaders": _headers_list(request.headers if request else None),
        "requestBody": body_req,
        "requestBodyTruncated": req_trunc,
        "responseHeaders": _headers_list(response.headers if response else None),
        "responseBody": body_res,
        "responseBodyTruncated": res_trunc,
        "durationMs": duration_ms,
        "bytesSent": bytes_sent,
        "bytesReceived": bytes_received,
        "clientPort": _peer_port(flow),
    }


def response(flow: http.HTTPFlow):
    _emit(_build_payload(flow))


def error(flow: http.HTTPFlow):
    message = None
    try:
        if flow.error is not None:
            message = str(flow.error)
    except Exception:
        message = "unknown error"
    _emit(_build_payload(flow, error_message=message))
