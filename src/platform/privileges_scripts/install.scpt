on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/ru.tvgubernia.rustdesk_service.plist && chown root:wheel /Library/LaunchDaemons/ru.tvgubernia.rustdesk_service.plist;"

  set sh2 to "echo " & quoted form of agent_file & " > /Library/LaunchAgents/ru.tvgubernia.rustdesk_server.plist && chown root:wheel /Library/LaunchAgents/ru.tvgubernia.rustdesk_server.plist;"

  set sh3 to "cp -rf /Users/" & user & "/Library/Preferences/ru.tvgubernia.rustdesk/RustDesk.toml /var/root/Library/Preferences/ru.tvgubernia.rustdesk/;"

  set sh4 to "cp -rf /Users/" & user & "/Library/Preferences/ru.tvgubernia.rustdesk/RustDesk2.toml /var/root/Library/Preferences/ru.tvgubernia.rustdesk/;"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/ru.tvgubernia.rustdesk_service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "RustDesk Gubernia wants to install daemon and agent" with administrator privileges
end run
