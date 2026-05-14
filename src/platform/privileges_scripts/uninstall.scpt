set sh1 to "launchctl unload -w /Library/LaunchDaemons/ru.tvgubernia.rustdesk_service.plist;"
set sh2 to "/bin/rm /Library/LaunchDaemons/ru.tvgubernia.rustdesk_service.plist;"
set sh3 to "/bin/rm /Library/LaunchAgents/ru.tvgubernia.rustdesk_server.plist;"

set sh to sh1 & sh2 & sh3
do shell script sh with prompt "RustDesk Gubernia wants to unload daemon" with administrator privileges