"""DNS-level mail checks, two public resolvers each (1.1.1.1 is unreachable
from this network, so 8.8.8.8 and 9.9.9.9). Never probes mailboxes.

    python3 dns_check.py hosts.txt out.json
"""
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

RESOLVERS = ("8.8.8.8", "9.9.9.9")


def query(host, rtype, server):
    for _ in range(3):
        p = subprocess.run(["dig", "+time=4", "+tries=2", f"@{server}", host, rtype],
                           capture_output=True, text=True)
        m = re.search(r"status: (\w+)", p.stdout)
        if m:
            ans = []
            sec = p.stdout.split(";; ANSWER SECTION:")
            if len(sec) > 1:
                for line in sec[1].split("\n\n")[0].strip().splitlines():
                    parts = line.split()
                    if len(parts) >= 5 and parts[3] == rtype:
                        ans.append(" ".join(parts[4:]))
            return m.group(1), ans
    return "TIMEOUT", []


def check(host):
    res = {}
    for s in RESOLVERS:
        st, mx = query(host, "MX", s)
        _, a = query(host, "A", s) if st == "NOERROR" else (st, [])
        _, aaaa = query(host, "AAAA", s) if st == "NOERROR" and not a else (st, [])
        null_mx = mx == ["0 ."]
        if st == "NXDOMAIN":
            verdict = "nxdomain"
        elif st != "NOERROR":
            verdict = "error:" + st
        elif null_mx:
            verdict = "null_mx"
        elif mx:
            verdict = "mx"
        elif a or aaaa:
            verdict = "a_only"
        else:
            verdict = "no_records"
        res[s] = {"status": st, "mx": mx, "a": a, "aaaa": aaaa, "verdict": verdict}
    verdicts = {v["verdict"] for v in res.values()}
    return host, {"resolvers": res, "verdict": verdicts.pop() if len(verdicts) == 1 else "disagree"}


if __name__ == "__main__":
    hosts = sorted({h.strip() for h in open(sys.argv[1]) if h.strip()})
    with ThreadPoolExecutor(16) as ex:
        out = dict(ex.map(check, hosts))
    json.dump(out, open(sys.argv[2], "w"), indent=1)
    import collections
    print(collections.Counter(v["verdict"] for v in out.values()))
