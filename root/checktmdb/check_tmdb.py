#!/usr/bin/env python3
import argparse
import ipaddress
import socket
import ssl
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from pathlib import Path

import requests


DOMAINS = [
    "tmdb.org",
    "api.tmdb.org",
    "files.tmdb.org",
    "themoviedb.org",
    "api.themoviedb.org",
    "www.themoviedb.org",
    "auth.themoviedb.org",
    "image.tmdb.org",
    "images.tmdb.org",
    "imdb.com",
    "www.imdb.com",
    "secure.imdb.com",
    "s.media-imdb.com",
    "us.dd.imdb.com",
    "www.imdb.to",
    "origin-www.imdb.com",
    "ia.media-imdb.com",
    "thetvdb.com",
    "api.thetvdb.com",
    "f.media-amazon.com",
    "imdb-video.media-imdb.com",
    "webservice.fanart.tv",
    "images.fanart.tv",
    "assets.fanart.tv",
    "fanart.tv",
    "api.trakt.tv",
    "trakt.tv",
]

COUNTRY_ECS = {
    "hk": "1.64.0.0/12",
    "sg": "103.6.148.0/22",
    "jp": "126.0.0.0/8",
    "us": "8.8.8.0/24",
}

# Some API domains may return 401/403/404 without credentials or a valid path.
# That still proves the selected IP can complete TCP + TLS + HTTP with correct SNI.
HTTPS_OK_STATUS_MAX = 499


def log(message):
    print(message, file=sys.stderr, flush=True)


def is_ip(value, version):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    return ip.version == version


def unique(items):
    seen = set()
    result = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


class DnsClient:
    def __init__(self, country, timeout):
        self.ecs = COUNTRY_ECS[country]
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update(
            {
                "accept": "application/dns-json, application/json, */*",
                "user-agent": "checktmdb/1.1",
            }
        )

    def _json_get(self, url, params, headers=None):
        response = self.session.get(
            url,
            params=params,
            headers=headers or {},
            timeout=self.timeout,
        )
        response.raise_for_status()
        return response.json()

    def _extract_ips(self, data, record_type):
        version = 6 if record_type == "AAAA" else 4
        answers = data.get("Answer") or []
        ips = []
        for answer in answers:
            value = str(answer.get("data", "")).strip()
            if is_ip(value, version):
                ips.append(value)
        return unique(ips)

    def query_alidns(self, domain, record_type):
        data = self._json_get(
            "https://dns.alidns.com/resolve",
            {
                "name": domain,
                "type": record_type,
                "edns_client_subnet": self.ecs,
            },
        )
        return self._extract_ips(data, record_type)

    def query_dnspod(self, domain, record_type):
        data = self._json_get(
            "https://doh.pub/dns-query",
            {
                "name": domain,
                "type": record_type,
            },
            headers={"accept": "application/dns-json"},
        )
        return self._extract_ips(data, record_type)

    def query_cloudflare(self, domain, record_type):
        data = self._json_get(
            "https://cloudflare-dns.com/dns-query",
            {
                "name": domain,
                "type": record_type,
            },
            headers={"accept": "application/dns-json"},
        )
        return self._extract_ips(data, record_type)

    def query_google(self, domain, record_type):
        data = self._json_get(
            "https://dns.google/resolve",
            {
                "name": domain,
                "type": record_type,
                "edns_client_subnet": self.ecs,
            },
        )
        return self._extract_ips(data, record_type)

    def query_system(self, domain, record_type):
        family = socket.AF_INET6 if record_type == "AAAA" else socket.AF_INET
        ips = []
        for item in socket.getaddrinfo(domain, None, family, socket.SOCK_STREAM):
            address = item[4][0]
            if is_ip(address, 6 if record_type == "AAAA" else 4):
                ips.append(address)
        return unique(ips)

    def query(self, domain, record_type):
        providers = [
            ("alidns", self.query_alidns),
            ("dnspod", self.query_dnspod),
            ("cloudflare", self.query_cloudflare),
            ("google", self.query_google),
            ("system", self.query_system),
        ]
        for name, provider in providers:
            try:
                ips = provider(domain, record_type)
            except Exception as exc:
                log(f"{record_type} {domain}: {name} failed: {exc}")
                continue
            if ips:
                log(f"{record_type} {domain}: {name} returned {', '.join(ips)}")
                return ips
        return []


def _format_connect_host(ip):
    # socket.create_connection accepts IPv6 literal directly, no bracket is needed.
    return ip


def https_probe(domain, ip, timeout):
    """Return (latency_ms, status_code) if HTTPS with SNI works, otherwise (None, None)."""
    start = time.monotonic()
    context = ssl.create_default_context()

    try:
        raw_sock = socket.create_connection((_format_connect_host(ip), 443), timeout=timeout)
        raw_sock.settimeout(timeout)
        with raw_sock:
            with context.wrap_socket(raw_sock, server_hostname=domain) as tls_sock:
                request = (
                    f"HEAD / HTTP/1.1\r\n"
                    f"Host: {domain}\r\n"
                    f"User-Agent: checktmdb/1.1\r\n"
                    f"Accept: */*\r\n"
                    f"Connection: close\r\n\r\n"
                ).encode("ascii")
                tls_sock.sendall(request)
                data = tls_sock.recv(256)
    except Exception:
        return None, None

    latency = int((time.monotonic() - start) * 1000)
    try:
        first_line = data.splitlines()[0].decode("iso-8859-1", errors="replace")
        parts = first_line.split()
        status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
    except Exception:
        status = 0

    if 100 <= status <= HTTPS_OK_STATUS_MAX:
        return latency, status

    return None, status


def tcp_latency(ip, timeout):
    best = None
    for port in (443, 80):
        start = time.monotonic()
        try:
            with socket.create_connection((ip, port), timeout=timeout):
                latency = int((time.monotonic() - start) * 1000)
                if best is None or latency < best:
                    best = latency
        except OSError:
            continue
    return best


def choose_ip(domain, ips, timeout, max_workers, probe_mode):
    fallback = ips[0] if ips else None
    best_ip = None
    best_latency = None

    worker_count = max(1, min(max_workers, len(ips) or 1))
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        if probe_mode == "tcp":
            futures = {executor.submit(tcp_latency, ip, timeout): ip for ip in ips}
        else:
            futures = {executor.submit(https_probe, domain, ip, timeout): ip for ip in ips}

        for future in as_completed(futures):
            ip = futures[future]
            try:
                result = future.result()
            except Exception as exc:
                log(f"test {domain} {ip}: failed: {exc}")
                continue

            if probe_mode == "tcp":
                latency = result
                status = None
            else:
                latency, status = result

            if latency is None:
                if status:
                    log(f"test {domain} {ip}: https failed, status={status}")
                else:
                    log(f"test {domain} {ip}: unreachable")
                continue

            if status:
                log(f"test {domain} {ip}: https {status}, {latency} ms")
            else:
                log(f"test {domain} {ip}: tcp {latency} ms")

            if best_latency is None or latency < best_latency:
                best_ip = ip
                best_latency = latency

    if best_ip:
        return best_ip

    if probe_mode == "https-with-tcp-fallback":
        log(f"test {domain}: no HTTPS candidate, fallback to TCP probe")
        return choose_ip(domain, ips, timeout, max_workers, "tcp")

    return fallback


def build_hosts(args):
    dns = DnsClient(args.country, args.dns_timeout)
    results = []

    for domain in DOMAINS:
        ipv4s = dns.query(domain, "A")
        ipv4 = choose_ip(domain, ipv4s, args.connect_timeout, args.workers, args.probe_mode)
        if ipv4:
            results.append((ipv4, domain))
            log(f"A {domain}: selected {ipv4}")
        else:
            log(f"A {domain}: skipped")

        if args.ipv6:
            ipv6s = dns.query(domain, "AAAA")
            ipv6 = choose_ip(domain, ipv6s, args.connect_timeout, args.workers, args.probe_mode)
            if ipv6:
                results.append((ipv6, domain))
                log(f"AAAA {domain}: selected {ipv6}")
            else:
                log(f"AAAA {domain}: skipped")

    return results


def render_hosts(results, country, ipv6, probe_mode):
    update_time = datetime.now(timezone(timedelta(hours=8))).replace(microsecond=0)
    lines = [
        "# CheckTMDB Hosts Start",
        f"# Country: {country}",
        f"# IPv6: {'1' if ipv6 else '0'}",
        f"# Probe mode: {probe_mode}",
    ]
    for ip, domain in results:
        lines.append(f"{ip:<45} {domain}")
    lines.extend(
        [
            f"# Update time: {update_time.isoformat()}",
            "# CheckTMDB Hosts End",
            "",
        ]
    )
    return "\n".join(lines)


def write_output(path, content):
    if path == "-":
        print(content, end="")
        return
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")


def parse_args():
    parser = argparse.ArgumentParser(description="Generate CheckTMDB hosts for ImmortalWrt.")
    parser.add_argument("--country", choices=sorted(COUNTRY_ECS), default="hk")
    parser.add_argument("--output", default="/tmp/checktmdb.hosts.new")
    parser.add_argument("--ipv6", action="store_true")
    parser.add_argument("--connect-timeout", "--timeout", dest="connect_timeout", type=float, default=1.5)
    parser.add_argument("--dns-timeout", type=float, default=5.0)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument(
        "--probe-mode",
        choices=("https", "https-with-tcp-fallback", "tcp"),
        default="https-with-tcp-fallback",
        help="https: require TCP+TLS+HTTP with SNI; tcp: old behavior; https-with-tcp-fallback: prefer HTTPS, fallback to TCP if no HTTPS candidate works",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    results = build_hosts(args)
    if not results:
        log("no hosts generated")
        return 1
    write_output(args.output, render_hosts(results, args.country, args.ipv6, args.probe_mode))
    log(f"generated {len(results)} hosts: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
