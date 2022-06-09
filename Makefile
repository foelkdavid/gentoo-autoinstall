all: copy

copy: install.sh
	scp -r . root@192.168.74.130:/tmp/installer
