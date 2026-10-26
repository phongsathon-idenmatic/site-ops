from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import os

HOST = "0.0.0.0"
PORT = 8000

# Always serve files from the folder containing this script
ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)

print(f"Serving: {ROOT}")
print(f"Port:    {PORT}")
print("Press Ctrl+C to stop.\n")

server = ThreadingHTTPServer((HOST, PORT), SimpleHTTPRequestHandler)

try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nServer stopped.")
finally:
    server.server_close()