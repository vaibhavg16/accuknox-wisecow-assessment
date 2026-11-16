#!/usr/bin/env python3
"""
Application Health Checker — HTTP uptime monitoring with retries,
status code validation, latency measurement, and structured output.
"""

import argparse
import json
import sys
import time
from dataclasses import dataclass, asdict
from typing import List, Optional
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


@dataclass
class HealthResult:
    url: str
    status: str  # "up" | "down" | "degraded"
    http_code: Optional[int]
    latency_ms: float
    timestamp: str
    error: Optional[str] = None


def create_session(retries: int, backoff: float, status_forcelist: List[int]) -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=retries,
        backoff_factor=backoff,
        status_forcelist=status_forcelist,
        allowed_methods=["HEAD", "GET", "OPTIONS"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


def check_url(session: requests.Session, url: str, timeout: float, expected_codes: List[int]) -> HealthResult:
    start = time.perf_counter()
    try:
        resp = session.get(url, timeout=timeout, allow_redirects=True)
        latency = (time.perf_counter() - start) * 1000
        if resp.status_code in expected_codes:
            status = "up"
        elif 400 <= resp.status_code < 500:
            status = "degraded"
        else:
            status = "down"
        return HealthResult(
            url=url,
            status=status,
            http_code=resp.status_code,
            latency_ms=round(latency, 2),
            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        )
    except requests.exceptions.Timeout:
        return HealthResult(url=url, status="down", http_code=None, latency_ms=timeout*1000,
                            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            error="Timeout")
    except requests.exceptions.ConnectionError as e:
        return HealthResult(url=url, status="down", http_code=None, latency_ms=0,
                            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            error=f"ConnectionError: {e}")
    except Exception as e:
        return HealthResult(url=url, status="down", http_code=None, latency_ms=0,
                            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            error=f"Unexpected: {e}")


def main():
    parser = argparse.ArgumentParser(description="HTTP Application Health Checker")
    parser.add_argument("urls", nargs="+", help="URLs to check")
    parser.add_argument("--timeout", type=float, default=5.0, help="Request timeout (seconds)")
    parser.add_argument("--retries", type=int, default=3, help="Retry count")
    parser.add_argument("--backoff", type=float, default=0.5, help="Retry backoff factor")
    parser.add_argument("--expected", type=int, nargs="+", default=[200], help="Expected HTTP codes")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    session = create_session(args.retries, args.backoff, [500, 502, 503, 504])
    results = [check_url(session, u, args.timeout, args.expected) for u in args.urls]

    if args.json:
        print(json.dumps([asdict(r) for r in results], indent=2))
    else:
        for r in results:
            icon = "✅" if r.status == "up" else "⚠️" if r.status == "degraded" else "❌"
            code = r.http_code or "N/A"
            err = f" — {r.error}" if r.error else ""
            print(f"{icon} {r.url} → {r.status.upper()} (HTTP {code}, {r.latency_ms:.1f}ms){err}")

    # Exit code: 0 if all up, 1 if any down, 2 if degraded
    if any(r.status == "down" for r in results):
        sys.exit(1)
    elif any(r.status == "degraded" for r in results):
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
