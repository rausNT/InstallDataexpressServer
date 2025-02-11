#!/bin/bash

log_file="/var/log/dataexpress_install.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$log_file"
}

log "Запуск установки DataExpress Web Server..."

# Проверка запуска от имени root
if [[ $EUID -ne 0 ]]; then
   log "Этот скрипт должен быть запущен от имени root. Выход."
   exit 1
fi

log "Обновление системных пакетов..."
sudo apt update -y && sudo apt upgrade -y

log "Установка необходимых зависимостей..."
sudo apt-get install -y libncurses5 openbsd-inetd nano ufw clamav unzip certbot

log "Установка Firebird 2.5..."
wget https://github.com/FirebirdSQL/firebird/releases/download/R2_5_9/FirebirdCS-2.5.9.27139-0.amd64.tar.gz
sudo tar -xzf FirebirdCS-2.5.9.27139-0.amd64.tar.gz
cd FirebirdCS-2.5.9.27139-0.amd64
sudo ./install.sh
cd ..
rm -rf FirebirdCS-2.5.9.27139-0.amd64*

log "Загрузка и установка DataExpress Web Server..."
wget https://mydataexpress.ru/files/dxwebsrv_linux64.tar.gz
sudo tar -xzf dxwebsrv_linux64.tar.gz -C /opt/
sudo chmod 744 /opt/dxwebsrv
rm dxwebsrv_linux64.tar.gz

log "Создание сервиса DataExpress..."
cat <<EOL | sudo tee /etc/systemd/system/dxwebsrv.service
[Unit]
Description=DataExpress Web Server
After=network.target

[Service]
ExecStart=/opt/dxwebsrv -r
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl enable dxwebsrv
sudo systemctl start dxwebsrv

log "Настройка брандмауэра..."
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp
sudo ufw allow 10000/tcp  # Webmin
sudo ufw enable

log "Установка и настройка Webmin..."
wget -qO- http://www.webmin.com/jcameron-key.asc | sudo tee /etc/apt/trusted.gpg.d/webmin.asc
sudo add-apt-repository "deb http://download.webmin.com/download/repository sarge contrib"
sudo apt update
sudo apt install -y webmin

log "Настройка Webmin для работы с Let's Encrypt..."
webmin_domain=$(hostname -I | awk '{print $1}')
sudo certbot certonly --standalone -d $webmin_domain --agree-tos --email admin@$webmin_domain --non-interactive
sudo sed -i "s|ssl_certfile=.*|ssl_certfile=/etc/letsencrypt/live/$webmin_domain/fullchain.pem|" /etc/webmin/miniserv.conf
sudo sed -i "s|ssl_keyfile=.*|ssl_keyfile=/etc/letsencrypt/live/$webmin_domain/privkey.pem|" /etc/webmin/miniserv.conf
sudo systemctl restart webmin

log "Обновление ClamAV и первичное сканирование..."
sudo freshclam
sudo clamscan -r /opt/dxwebsrv

log "Загрузка и установка тестовой базы данных..."
wget -O /tmp/dataexpress.zip "https://mydataexpress.ru/files/dataexpress.zip?r=4986"
sudo unzip /tmp/dataexpress.zip -d /home/bases/
sudo chown -R firebird:firebird /home/bases/
sudo chmod -R 750 /home/bases/
sudo find /home/bases/ -type f -exec chmod 640 {} \;
sudo chmod -R 640 /var/lib/firebird/data/
rm /tmp/dataexpress.zip

# Определение IP-адреса сервера
server_ip=$(hostname -I | awk '{print $1}')

cat <<EOM
============================================
УСТАНОВКА ЗАВЕРШЕНА
============================================
DataExpress Web Server запущен на порту 8080.
Откройте в браузере: http://$server_ip:8080

Для подключения к тестовой базе данных используйте:
  Строка подключения: $server_ip:/home/bases/dataexpress.fdb
  Пользователь: SYSDBA
  Пароль: masterkey

Webmin установлен и использует SSL.
Доступен по адресу: https://$server_ip:10000 (вход через root).
============================================
EOM
