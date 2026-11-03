#!/usr/bin/env python3
"""Call both tiers through the load balancer and check the answers."""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def load_dotenv(path="../.env"):
    """Read KEY=VALUE lines from a .env style file into a dict."""
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def get(url, timeout=30):
    """Return (status, parsed JSON or text). HTTP errors are returned, not raised."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body, status = resp.read().decode(), resp.status
    except urllib.error.HTTPError as err:
        body, status = err.read().decode(), err.code
    except (urllib.error.URLError, TimeoutError) as err:
        return 0, {"error": f"no connection: {err}"}
    try:
        return status, json.loads(body)
    except ValueError:
        return status, body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", default="60616", help="zip code for the happy-path checks")
    args = parser.parse_args()

    env = load_dotenv()
    alb = load_dotenv("../stack_outputs.env")["ALB_DNS_NAME"]
    weather = f"http://{alb}:{env['WEATHER_LISTENER_PORT']}"
    advisor = f"http://{alb}:{env['ADVISOR_LISTENER_PORT']}"

    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}   {name}   {detail}")

    status, body = get(f"{weather}/weather?zip={args.zip}")
    check("weather tier returns a forecast", status == 200 and "forecast" in body, f"status {status}")

    status, body = get(f"{weather}/weather?zip={args.zip}")
    check("a repeat call is answered from the database (cache hit)",
          status == 200 and body.get("cache") == "hit", f"cache={body.get('cache') if isinstance(body, dict) else body}")

    status, body = get(f"{weather}/history")
    check("history lists the saved lookups", status == 200 and body.get("count", 0) >= 1,
          f"status {status}, count={body.get('count') if isinstance(body, dict) else '?'}")

    status, body = get(f"{weather}/weather?zip=abc")
    check("weather tier rejects a bad zip with 400", status == 400, f"status {status}")

    status, body = get(f"{weather}/weather?zip=00000")
    check("weather tier returns 404 for an unknown zip", status == 404, f"status {status}")

    t0 = time.time()
    status, body = get(f"{advisor}/advice?zip={args.zip}")
    ok = status == 200 and bool(body.get("advice"))
    check("advisor tier returns clothing advice", ok, f"status {status}, {time.time() - t0:.1f}s")
    if ok:
        print(f"      source={body.get('source')} model={body.get('model')}")
        print(f"      advice: {body['advice']}")
        check("advice came from Gemini (not the fallback)", body.get("source") == "gemini",
              "fallback means the key, quota or model name needs a look")

    status, body = get(f"{advisor}/advice?zip=abc")
    check("advisor tier rejects a bad zip with 400", status == 400, f"status {status}")

    status, body = get(f"{advisor}/")
    check("advisor home page loads", status == 200 and "<form" in str(body), f"status {status}")

    print(f"\n{sum(results)} of {len(results)} checks passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()