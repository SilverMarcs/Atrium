"""Read-only ACP/account fixture. No credentials, real CLI or conversations."""
import http.server
import json
import os
import sys
import threading
import time

mode = "signed-in"
methods = []


class Account(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        status = 200
        if mode == "slow":
            time.sleep(6)
        if mode == "signed-out":
            status, body = 401, {"code": "unauthenticated", "message": "Please sign in."}
        elif mode == "offline":
            status, body = 503, {"code": "unavailable", "message": "Temporarily unavailable."}
        elif mode == "empty":
            body = {}
        elif mode == "plan-only":
            body = {"userStatus": {"planStatus": {"planInfo": {"planName": "Pro"}}}}
        else:
            body = {"userStatus": {"userTier": {"name": "Google AI Pro"}}}
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(json.dumps(body).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Account)
threading.Thread(target=server.serve_forever, daemon=True).start()
log = sys.argv[sys.argv.index("--log-file") + 1]
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    methods.append(method)
    result = {}
    if method == "initialize":
        time.sleep(0.15)
    elif method == "session/list":
        if mode == "list-fails":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                              "error": {"code": -32603, "message": "Conversation listing unavailable."}}), flush=True)
            continue
        # The real CLI starts its language server on the first session RPC.
        with open(log, "w") as file:
            file.write(f"listening on random port at {server.server_port} for HTTP\n")
        result = {"sessions": []}
    elif method == "fixture/mode":
        mode = request["params"]["value"]
    elif method == "fixture/state":
        result = {"methods": methods, "pid": os.getpid()}
    elif method.startswith("session/"):
        raise AssertionError(f"Account lookup touched a conversation: {method}")
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
