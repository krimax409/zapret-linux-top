@echo off
start "zapret" /min "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443 --filter-tcp=443 --hostlist-domains=%FutureVariable% --dpi-desync=fake
