#!/usr/bin/env python3
"""Look up host credentials in IT2G IPAM (phpIPAM) by IP address.

Reads IPAM web credentials from ~/.config/it2g/domain.creds (username:password),
logs in to https://ipam.it2g.ru, finds the address entry for the given IP and
prints its fields as JSON on stdout.

Usage: ipam-lookup.py <ip> [--refresh] [--cache-dir DIR] [--ttl SECONDS]
       ipam-lookup.py --selftest
"""
import argparse
import http.cookiejar
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request

IPAM_URL = os.environ.get("IT2G_IPAM_URL", "https://ipam.it2g.ru")
CREDS = os.path.expanduser(
    os.environ.get("IT2G_IPAM_CREDS", "~/.config/it2g/domain.creds")
)
CACHE_DIR = os.path.expanduser("~/.cache/it2g-ssh")
TTL = 12 * 3600

FIELDS = {
    "Логин": "user",
    "Пароль": "password",
    "Root_Login": "root_user",
    "Root_Password": "root_password",
    "Имя хоста": "hostname",
    "Описание": "description",
    "Подсеть": "subnet",
    "IP статус": "status",
}


def die(msg, code=1):
    print("ipam-lookup: " + msg, file=sys.stderr)
    sys.exit(code)


def read_ipam_creds():
    if not os.path.exists(CREDS):
        die("нет файла с кредами IPAM: %s" % CREDS)
    with open(CREDS, encoding="utf-8") as fh:
        line = fh.readline().rstrip("\r\n")
    if ":" not in line:
        die("%s: ожидается формат username:password" % CREDS)
    user, password = line.split(":", 1)
    return user, password


class IPAMClient:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        )

    def request(self, path, data=None):
        body = urllib.parse.urlencode(data).encode() if data else None
        req = urllib.request.Request(IPAM_URL + path, data=body)
        req.add_header("User-Agent", "it2g-ssh/1.0")
        try:
            with self.opener.open(req, timeout=40) as resp:
                return resp.read().decode("utf-8", "replace")
        except urllib.error.URLError as exc:
            if isinstance(getattr(exc, "reason", exc), ssl.SSLCertVerificationError):
                die(
                    "TLS-проверка %s не прошла: узел не отдал полную цепочку "
                    "сертификатов (%s)" % (IPAM_URL, exc.reason)
                )
            raise

    def login(self):
        user, password = read_ipam_creds()
        self.request("/index.php?page=login")
        out = self.request(
            "/app/login/login_check.php",
            {
                "ipamusername": user,
                "ipampassword": password,
                "phpipamredirect": "/index.php?page=tools&section=search",
            },
        )
        if "alert alert-success" not in out:
            text = re.sub(r"<[^>]+>", " ", out)
            text = re.sub(r"\s+", " ", text).strip()
            die("не удалось залогиниться в IPAM (%s): %s" % (user, text[:200]))

    def find_address(self, ip):
        out = self.request(
            "/index.php?page=tools&section=search&ip=%s&subnets=on&addresses=on"
            % urllib.parse.quote(ip)
        )
        hits = []
        for attrs, body in re.findall(r'<tr class="ipSearch"([^>]*)>(.*?)</tr>', out, re.S):
            found = re.search(r'<td class="ip">.*?>(\d{1,3}(?:\.\d{1,3}){3})<', body, re.S)
            if not found:
                continue
            attr = dict(re.findall(r'(\w+)="(\d+)"', attrs))
            hits.append(
                {
                    "ip": found.group(1),
                    "ipaddrid": attr.get("id"),
                    "subnetId": attr.get("subnetId"),
                    "sectionId": attr.get("sectionId"),
                }
            )
        exact = [h for h in hits if h["ip"] == ip]
        if not exact:
            others = ", ".join(h["ip"] for h in hits) or "нет совпадений"
            die("%s не найден в IPAM (поиск вернул: %s)" % (ip, others), 2)
        best = exact[0]
        if not (best["ipaddrid"] and best["subnetId"] and best["sectionId"]):
            die("не удалось разобрать строку поиска для %s" % ip, 3)
        return best

    def address_details(self, hit):
        out = self.request(
            "/index.php?page=subnets&section=%s&subnetId=%s&sPage=address-details&ipaddrid=%s"
            % (hit["sectionId"], hit["subnetId"], hit["ipaddrid"])
        )
        fields = {"subnet_id": hit["subnetId"], "section_id": hit["sectionId"]}
        for row in re.findall(r"<tr[^>]*>(.*?)</tr>", out, re.S):
            cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)
            if len(cells) != 2:
                continue

            def clean(x):
                x = re.sub(r"<[^>]+>", " ", x)
                x = x.replace("&nbsp;", " ")
                return re.sub(r"\s+", " ", x).strip()

            label, value = clean(cells[0]), clean(cells[1])
            if label in FIELDS:
                fields[FIELDS[label]] = "" if value == "/" else value
        return fields


def cache_path(cache_dir, ip):
    return os.path.join(cache_dir, ip + ".json")


def load_cache(cache_dir, ip, ttl):
    path = cache_path(cache_dir, ip)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if ttl and time.time() - data.get("_fetched_at", 0) > ttl:
        return None
    return data


def save_cache(cache_dir, ip, data):
    os.makedirs(cache_dir, mode=0o700, exist_ok=True)
    path = cache_path(cache_dir, ip)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def lookup(ip, cache_dir, ttl, refresh):
    if not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip):
        die("ожидается IPv4-адрес, получено: %r" % ip)
    if not refresh:
        cached = load_cache(cache_dir, ip, ttl)
        if cached:
            return cached
    api = IPAMClient()
    api.login()
    hit = api.find_address(ip)
    data = {"ip": ip, "ipam_id": int(hit["ipaddrid"])}
    data.update(api.address_details(hit))
    data["_fetched_at"] = int(time.time())
    save_cache(cache_dir, ip, data)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ip")
    ap.add_argument("--refresh", action="store_true", help="игнорировать кэш")
    ap.add_argument("--cache-dir", default=CACHE_DIR)
    ap.add_argument("--ttl", type=int, default=TTL, help="время жизни кэша, сек (0 = вечный)")
    args = ap.parse_args()
    print(json.dumps(lookup(args.ip, args.cache_dir, args.ttl, args.refresh),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
