@echo off
start "one" /min "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --filter-tcp=443 --dpi-desync=fake
start "two" /min "%BIN%winws.exe" --wf-tcp=80 --wf-udp=443 --filter-tcp=80 --dpi-desync=fake
