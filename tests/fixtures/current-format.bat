@echo off
call service.bat load_game_filter
call service.bat load_user_lists
set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
start "zapret" /min "%BIN%winws.exe" --wf-tcp=80,443,%GameFilterTCP% --wf-udp=443,%GameFilterUDP% ^
--filter-tcp=443 --hostlist="%LISTS%list-general-user.txt" --dpi-desync=fake,multisplit --dpi-desync-split-seqovl-pattern="%BIN%fake.bin" --new ^
--filter-tcp=%GameFilterTCP% --dpi-desync=fake --new ^
--filter-udp=%GameFilterUDP% --dpi-desync=fake
