#!/usr/bin/env python3
"""A TCP listener that notes how many bytes each connection sent, never what they were."""
import socket
import sys

server = socket.create_server(("127.0.0.1", int(sys.argv[1])))
while True:
    conn, _ = server.accept()
    with conn, open(sys.argv[2], "a") as log:
        print(len(conn.recv(65536)), file=log)
