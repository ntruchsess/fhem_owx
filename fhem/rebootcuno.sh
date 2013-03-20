#!/usr/bin/expect 

set timeout 20 
#set name [lindex $argv 0] 
#set user [lindex $argv 1] 
#set password [lindex $argv 2] 
spawn telnet 192.168.0.91 2323
expect "Escape character is '^]'."
send "B"
