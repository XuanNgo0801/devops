import requests
import datetime
import time

# ============================
# 🔧 CONFIG
# ============================
LOKI_URL = "http://your-loki-endpoint:3100"  # ví dụ http://loki.monitoring.svc.cluster.local:3100
QUERY = '{app="my-app"} |= "exception"'      # biểu thức Loki LogQL
START_TIME = "2025-10-06 12:00:00"           # định dạng YYYY-MM-DD HH:MM:SS
END_TIME = "2025-10-06 14:00:00"
CONTEXT_LINES = 5                            # số dòng trước/sau cần lấy
OUTPUT_FILE = "logs_with_context.txt"

# ============================
# ⚙️ Convert & build query
# ============================

def to_ns(ts_str):
    """Chuyển datetime string sang epoch nanoseconds"""
    dt = datetime.datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
    return int(dt.timestamp() * 1e9)

start_ns = to_ns(START_TIME)
end_ns = to_ns(END_TIME)

# ============================
# 🚀 Query logs từ Loki
# ============================

def query_loki(query, start_ns, end_ns):
    url = f"{LOKI_URL}/loki/api/v1/query_range"
    params = {
        "query": query,
        "start": start_ns,
        "end": end_ns,
        "limit": 1000,
        "direction": "forward"
    }
    r = requests.get(url, params=params)
    r.raise_for_status()
    return r.json()

# ============================
# 🔍 Lấy context quanh log
# ============================

def get_context(loki_url, stream, ts, context_lines):
    """Lấy log trước/sau 1 dòng theo timestamp"""
    context = []

    # Lấy trước
    before_url = f"{loki_url}/loki/api/v1/query_range"
    before_params = {
        "query": stream,
        "end": ts,
        "limit": context_lines,
        "direction": "backward"
    }
    before = requests.get(before_url, params=before_params).json()
    for result in before.get("data", {}).get("result", []):
        for value in result.get("values", []):
            context.append(f"[BEFORE] {value[1]}")

    # Lấy sau
    after_url = f"{loki_url}/loki/api/v1/query_range"
    after_params = {
        "query": stream,
        "start": ts,
        "limit": context_lines,
        "direction": "forward"
    }
    after = requests.get(after_url, params=after_params).json()
    for result in after.get("data", {}).get("result", []):
        for value in result.get("values", []):
            context.append(f"[AFTER] {value[1]}")

    return context

# ============================
# 📝 Ghi ra file
# ============================

def main():
    data = query_loki(QUERY, start_ns, end_ns)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        results = data.get("data", {}).get("result", [])
        if not results:
            f.write("Không tìm thấy log nào.\n")
            print("❌ Không có log khớp query.")
            return

        for res in results:
            stream = res.get("stream")
            for val in res.get("values", []):
                ts = val[0]
                log_line = val[1]
                f.write(f"==== Log chính ====\n{log_line}\n")

                context_logs = get_context(LOKI_URL, QUERY, ts, CONTEXT_LINES)
                for c in context_logs:
                    f.write(c + "\n")
                f.write("\n")

    print(f"✅ Đã lưu log (kèm context) vào file: {OUTPUT_FILE}")

if __name__ == "__main__":
    main()