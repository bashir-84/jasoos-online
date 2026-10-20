"""Serve this folder on this computer only, using Python 3."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from functools import partial
import webbrowser

if __name__ == '__main__':
    root = Path(__file__).resolve().parent
    for port in range(8080, 8090):
        try:
            server = ThreadingHTTPServer(('127.0.0.1', port), partial(SimpleHTTPRequestHandler, directory=str(root)))
            break
        except OSError:
            continue
    else:
        raise SystemExit('Ports 8080–8089 are busy.')
    url = f'http://127.0.0.1:{port}/'
    print(f'Jasoos: {url}\nPress Ctrl+C to stop.')
    webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
