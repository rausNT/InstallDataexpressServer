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

# Запрос пути к пользовательской базе или загрузка тестовой
read -p "Хотите загрузить свою базу данных? (y/n): " use_custom_db
if [[ "$use_custom_db" == "y" ]]; then
    read -p "Введите полный путь к файлу базы данных на вашем компьютере: " custom_db_path
    if [[ -f "$custom_db_path" ]]; then
        sudo cp "$custom_db_path" /var/lib/firebird/data/custom_database.fdb
        sudo chown firebird:firebird /var/lib/firebird/data/custom_database.fdb
        sudo chmod 640 /var/lib/firebird/data/custom_database.fdb
        log "Пользовательская база данных загружена и установлена."
    else
        log "Ошибка: Файл базы данных не найден. Загружается тестовая база."
        use_custom_db="n"
    fi
fi

if [[ "$use_custom_db" != "y" ]]; then
    log "Загрузка и установка тестовой базы данных..."
    wget -O /tmp/dataexpress.zip "https://mydataexpress.ru/files/dataexpress.zip?r=4986"
    sudo unzip /tmp/dataexpress.zip -d /var/lib/firebird/data/
    sudo chown -R firebird:firebird /var/lib/firebird/data/
    sudo chmod -R 640 /var/lib/firebird/data/
    rm /tmp/dataexpress.zip
fi

# Определение IP-адреса сервера
server_ip=$(hostname -I | awk '{print $1}')

log "Установка завершена. DataExpress Web Server запущен на порту 8080."
log "Для доступа к серверу откройте http://$server_ip:8080 в браузере."
if [[ "$use_custom_db" == "y" ]]; then
    log "Для подключения к вашей базе используйте строку подключения: '$server_ip:/var/lib/firebird/data/custom_database.fdb' с пользователем 'SYSDBA' и паролем 'masterkey'."
else
    log "Для подключения к тестовой базе используйте строку подключения: '$server_ip:/var/lib/firebird/data/dataexpress.fdb' с пользователем 'SYSDBA' и паролем 'masterkey'."
fi
log "Webmin установлен и использует SSL. Доступен по адресу: https://$server_ip:10000 (вход через root)."
